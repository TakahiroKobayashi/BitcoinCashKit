//
//  Script.swift
//
//  Copyright © 2018 Kishikawa Katsumi
//  Copyright © 2018 BitcoinCashKit developers
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

public class Script {
    // An array of Data objects (pushing data) or UInt8 objects (containing opcodes)
    private var chunks: [ScriptChunk]

    // Cached serialized representations for -data and -string methods.
    private var dataCache: Data?
    private var stringCache: String?

    public var data: Data {
        // When we calculate data from scratch, it's important to respect actual offsets in the chunks as they may have been copied or shifted in subScript* methods.
        if let cache = dataCache {
            return cache
        }
        dataCache = chunks.reduce(Data()) { $0 + $1.chunkData }
        return dataCache!
    }

    public var string: String {
        if let cache = stringCache {
            return cache
        }
        stringCache = chunks.map { $0.string }.joined(separator: " ")
        return stringCache!
    }

    public var hex: String {
        return data.hex
    }

    // Multisignature script attribute.
    // If multisig script is not detected, this is nil
    public typealias MultisigVariables = (nSigRequired: UInt, publickeys: [PublicKey])
    public var multisigRequirements: MultisigVariables?

    public init() {
        self.chunks = [ScriptChunk]()
    }

    public init(chunks: [ScriptChunk]) {
        self.chunks = chunks
    }

    public convenience init?(data: Data) {
        // It's important to keep around original data to correctly identify the size of the script for BTC_MAX_SCRIPT_SIZE check
        // and to correctly calculate hash for the signature because in BitcoinQT scripts are not re-serialized/canonicalized.
        guard let chunks = Script.parseData(data) else {
            return nil
        }
        self.init(chunks: chunks)
    }

    public convenience init?(hex: String) {
        guard let scriptData = Data(hex: hex) else {
            return nil
        }
        self.init(data: scriptData)
    }

    public convenience init?(address: Address) {
        var scriptData: Data = Data()

        switch address.type {
        case .pubkeyHash:
            // OP_DUP OP_HASH160 <hash> OP_EQUALVERIFY OP_CHECKSIG
            scriptData += OpCode.OP_DUP
            scriptData += OpCode.OP_HASH160

            guard let addressData = ScriptChunkHelper.scriptData(for: address.data, preferredLengthEncoding: -1) else {
                return nil
            }
            scriptData += addressData

            scriptData += OpCode.OP_EQUALVERIFY
            scriptData += OpCode.OP_CHECKSIG
        case .scriptHash:
            // OP_HASH160 <hash> OP_EQUAL
            scriptData += OpCode.OP_HASH160

            guard let addressData = ScriptChunkHelper.scriptData(for: address.data, preferredLengthEncoding: -1) else {
                return nil
            }
            scriptData += addressData

            scriptData += OpCode.OP_EQUAL
        default:
            return nil
        }
        self.init(data: scriptData)
    }

    // OP_<M> <pubkey1> ... <pubkeyN> OP_<N> OP_CHECKMULTISIG
    public convenience init?(publicKeys: [PublicKey], signaturesRequired: UInt) {
        // First make sure the arguments make sense.
        // We need at least one signature
        guard signaturesRequired > 0 else {
            return nil
        }

        // And we cannot have more signatures than available pubkeys.
        guard publicKeys.count >= signaturesRequired else {
            return nil
        }

        // Both M and N should map to OP_<1..16>
        let mOpcode: OpCodeProtocol = OpCodeFactory.opcodeForSmallInteger(smallInteger: Int(signaturesRequired))
        let nOpcode: OpCodeProtocol = OpCodeFactory.opcodeForSmallInteger(smallInteger: publicKeys.count)

        guard mOpcode != OpCode.OP_INVALIDOPCODE else {
            return nil
        }
        guard nOpcode != OpCode.OP_INVALIDOPCODE else {
            return nil
        }

        var scriptData: Data = Data()
        scriptData += mOpcode

        for pubkey in publicKeys {
            guard let pubkeyScriptData = ScriptChunkHelper.scriptData(for: pubkey.raw, preferredLengthEncoding: -1) else {
                return nil // invalid data
            }
            scriptData += pubkeyScriptData
        }

        scriptData += nOpcode
        scriptData += OpCode.OP_CHECKMULTISIG

        self.init(data: scriptData)
        self.multisigRequirements = (signaturesRequired, publicKeys)
    }

    private static func parseData(_ data: Data) -> [ScriptChunk]? {
        guard !data.isEmpty else {
            return [ScriptChunk]()
        }

        var chunks = [ScriptChunk]()

        var i: Int = 0
        let count: Int = data.count

        while i < count {
            // Exit if failed to parse
            guard let chunk = ScriptChunkHelper.parseChunk(from: data, offset: i) else {
                return nil
            }
            chunks.append(chunk)

            i += chunk.range.count
        }
        return chunks
    }

    public var isStandard: Bool {
        return isPayToPublicKeyHashScript
            || isPayToScriptHashScript
            || isPublicKeyScript
            || isStandardMultisignatureScript
    }

    public var isPublicKeyScript: Bool {
        guard chunks.count == 2 else {
            return false
        }
        guard let pushdata = pushedData(at: 0) else {
            return false
        }
        return pushdata.count > 1 && opcode(at: 1) == OpCode.OP_CHECKSIG
    }

    public var isPayToPublicKeyHashScript: Bool {
        guard chunks.count == 5 else {
            return false
        }
        guard let dataChunk = chunk(at: 2) as? DataChunk else {
            return false
        }
        return opcode(at: 0) == OpCode.OP_DUP
            && opcode(at: 1) == OpCode.OP_HASH160
            && dataChunk.range.count == 21
            && opcode(at: 3) == OpCode.OP_EQUALVERIFY
            && opcode(at: 4) == OpCode.OP_CHECKSIG
    }

    // TODO: check against the original serialized form instead of parsed chunks because BIP16 defines
    // P2SH script as an exact byte template. Scripts using OP_PUSHDATA1/2/4 are not valid P2SH scripts.
    // To do that we have to maintain original script binary data and each chunk should keep a range in that data.
    public var isPayToScriptHashScript: Bool {
        guard chunks.count == 3 else {
            return false
        }
        return opcode(at: 0) == OpCode.OP_HASH160
            && pushedData(at: 1)?.count == 20 // this is enough to match the exact byte template, any other encoding will be larger.
            && opcode(at: 2) == OpCode.OP_EQUAL
    }

    // Returns true if the script ends with P2SH check.
    // Not used in CoreBitcoin. Similar code is used in bitcoin-ruby. I don't know if we'll ever need it.
    public var endsWithPayToScriptHash: Bool {
        guard chunks.count >= 3 else {
            return false
        }
        return opcode(at: -3) == OpCode.OP_HASH160
            && pushedData(at: -2)?.count == 20
            && opcode(at: -1) == OpCode.OP_EQUAL
    }

    public var isStandardMultisignatureScript: Bool {
        guard isMultisignatureScript else {
            return false
        }
        guard let multisigPublicKeys = multisigRequirements?.publickeys else {
            return false
        }
        return multisigPublicKeys.count <= 3
    }

    public var isMultisignatureScript: Bool {
        guard let requirements = multisigRequirements else {
            return false
        }
        if requirements.nSigRequired == 0 {
            detectMultisigScript()
        }

        return requirements.nSigRequired > 0
    }

    // If typical multisig tx is detected, sets requirements:
    private func detectMultisigScript() {
        // multisig script must have at least 4 ops ("OP_1 <pubkey> OP_1 OP_CHECKMULTISIG")
        guard chunks.count >= 4 else {
            return
        }

        // The last op is multisig check.
        guard opcode(at: -1) == OpCode.OP_CHECKMULTISIG else {
            return
        }

        let mOpcode: OpCodeProtocol = opcode(at: 0)
        let nOpcode: OpCodeProtocol = opcode(at: -2)

        let m: Int = OpCodeFactory.smallIntegerFromOpcode(opcode: mOpcode)
        let n: Int = OpCodeFactory.smallIntegerFromOpcode(opcode: nOpcode)

        guard m > 0 && m != Int.max else {
            return
        }
        guard n > 0 && n != Int.max && n >= m else {
            return
        }

        // We must have correct number of pubkeys in the script. 3 extra ops: OP_<M>, OP_<N> and OP_CHECKMULTISIG
        guard chunks.count == 3 + n else {
            return
        }

        var pubkeys: [PublicKey] = []
        for i in 0...n {
            guard let data = pushedData(at: i) else {
                return
            }
            let pubkey = PublicKey(bytes: data, network: .mainnet)
            pubkeys.append(pubkey)
        }

        // Now we extracted all pubkeys and verified the numbers.
        multisigRequirements = (UInt(m), pubkeys)
    }

    // Include both PUSHDATA ops and OP_0..OP_16 literals.
    public var isDataOnly: Bool {
        return !chunks.contains { $0.opCode > OpCode.OP_16 }
    }

    public var scriptChunks: [ScriptChunk] {
        return chunks
    }

    public func standardAddress(network: Network) -> Address? {
        if isPayToPublicKeyHashScript {
            guard let dataChunk = chunk(at: 2) as? DataChunk else {
                return nil
            }
            return Cashaddr(data: dataChunk.pushedData, type: .pubkeyHash, network: network)
        } else if isPayToScriptHashScript {
            guard let dataChunk = chunk(at: 1) as? DataChunk else {
                return nil
            }
            return Cashaddr(data: dataChunk.pushedData, type: .pubkeyHash, network: network)
        }
        return nil
    }

    // MARK: - Modification
    public func invalidateSerialization() {
        dataCache = nil
        stringCache = nil
        multisigRequirements = nil
    }

    private func update(with updatedData: Data) throws {
        guard let updatedChunks = Script.parseData(updatedData) else {
            throw ScriptError.error("Parse data failed while updating. : \(updatedData.hex)")
        }
        chunks = updatedChunks
        invalidateSerialization()
    }

    public func append(_ opcode: OpCodeProtocol) throws {
        let invalidOpCodes: [OpCodeProtocol] = [OpCode.OP_PUSHDATA1,
                                                OpCode.OP_PUSHDATA2,
                                                OpCode.OP_PUSHDATA4,
                                                OpCode.OP_INVALIDOPCODE]
        guard !invalidOpCodes.contains(where: { $0 == opcode }) else {
            throw ScriptError.error("\(opcode.name) cannot be executed alone.")
        }
        var updatedData: Data = data
        updatedData += opcode
        try update(with: updatedData)
    }

    public func append(_ newData: Data) throws {
        guard !newData.isEmpty else {
            throw ScriptError.error("Data is empty.")
        }

        guard let addedScriptData = ScriptChunkHelper.scriptData(for: newData, preferredLengthEncoding: -1) else {
            throw ScriptError.error("Parse data to pushdata failed.")
        }
        var updatedData: Data = data
        updatedData += addedScriptData
        try update(with: updatedData)
    }

    public func append(_ otherScript: Script) throws {
        guard !otherScript.data.isEmpty else {
            throw ScriptError.error("Script is empty.")
        }

        var updatedData: Data = self.data
        updatedData += otherScript.data
        try update(with: updatedData)
    }

    public func deleteOccurrences(of data: Data) throws {
        guard !data.isEmpty else {
            return
        }

        let updatedData = chunks.filter { ($0 as? DataChunk)?.pushedData != data }.reduce(Data()) { $0 + $1.chunkData }
        try update(with: updatedData)
    }

    public func deleteOccurrences(of opcode: UInt8) throws {
        let updatedData = chunks.filter { $0.opCode != opcode }.reduce(Data()) { $0 + $1.chunkData }
        try update(with: updatedData)
    }

    public func subScript(from index: Int) throws -> Script {
        let subScript: Script = Script()
        for chunk in chunks[Range(index..<chunks.count)] {
            try subScript.append(chunk.chunkData)
        }
        return subScript
    }

    public func subScript(to index: Int) throws -> Script {
        let subScript: Script = Script()
        for chunk in chunks[Range(0..<index)] {
            try subScript.append(chunk.chunkData)
        }
        return subScript
    }

    // MARK: - Utility methods
    // Raise exception if index is out of bounds
    public func chunk(at index: Int) -> ScriptChunk {
        return chunks[index < 0 ? chunks.count + index : index]
    }

    // Returns an opcode in a chunk.
    // If the chunk is data, not an opcode, returns OP_INVALIDOPCODE
    // Raises exception if index is out of bounds.
    public func opcode(at index: Int) -> OpCodeProtocol {
        let chunk = self.chunk(at: index)
        // If the chunk is not actually an opcode, return invalid opcode.
        guard chunk is OpcodeChunk else {
            return OpCode.OP_INVALIDOPCODE
        }
        return chunk.opCode
    }

    // Returns Data in a chunk.
    // If chunk is actually an opcode, returns nil.
    // Raises exception if index is out of bounds.
    public func pushedData(at index: Int) -> Data? {
        let chunk = self.chunk(at: index)
        return (chunk as? DataChunk)?.pushedData
    }

    public func execute(with context: ScriptExecutionContext) throws {
        for chunk in chunks {
            if let opChunk = chunk as? OpcodeChunk {
                try opChunk.opCode.execute(context)
            } else if let dataChunk = chunk as? DataChunk {
                try context.pushToStack(dataChunk.pushedData)
            } else {
                throw ScriptMachineError.error("Unknown chunk")
            }
        }

        guard context.conditionStack.isEmpty else {
            throw ScriptMachineError.error("Condition branches not balanced.")
        }
    }
}

extension Script {
    // Standard Transaction to Bitcoin address (pay-to-pubkey-hash)
    // scriptPubKey: OP_DUP OP_HASH160 <pubKeyHash> OP_EQUALVERIFY OP_CHECKSIG
    public static func buildPublicKeyHashOut(pubKeyHash: Data) -> Data {
        let tmp: Data = Data() + OpCode.OP_DUP + OpCode.OP_HASH160 + UInt8(pubKeyHash.count) + pubKeyHash + OpCode.OP_EQUALVERIFY
        return tmp + OpCode.OP_CHECKSIG
    }

    public static func buildPublicKeyUnlockingScript(signature: Data, pubkey: PublicKey, hashType: SighashType) -> Data {
        var data: Data = Data([UInt8(signature.count + 1)]) + signature + UInt8(hashType)
        data += VarInt(pubkey.raw.count).serialized()
        data += pubkey.raw
        return data
    }

    public static func isPublicKeyHashOut(_ script: Data) -> Bool {
        return script.count == 25 &&
            script[0] == OpCode.OP_DUP && script[1] == OpCode.OP_HASH160 && script[2] == 20 &&
            script[23] == OpCode.OP_EQUALVERIFY && script[24] == OpCode.OP_CHECKSIG
    }

    public static func getPublicKeyHash(from script: Data) -> Data {
        return script[3..<23]
    }
}

extension Script: CustomStringConvertible {
    public var description: String {
        return string
    }
}

enum ScriptError: Error {
    case error(String)
}