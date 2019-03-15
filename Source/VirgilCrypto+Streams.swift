//
// Copyright (C) 2015-2019 Virgil Security Inc.
//
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//     (1) Redistributions of source code must retain the above copyright
//     notice, this list of conditions and the following disclaimer.
//
//     (2) Redistributions in binary form must reproduce the above copyright
//     notice, this list of conditions and the following disclaimer in
//     the documentation and/or other materials provided with the
//     distribution.
//
//     (3) Neither the name of the copyright holder nor the names of its
//     contributors may be used to endorse or promote products derived from
//     this software without specific prior written permission.
//
// THIS SOFTWARE IS PROVIDED BY THE AUTHOR ''AS IS'' AND ANY EXPRESS OR
// IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
// WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
// DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
// INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
// (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
// SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
// HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
// STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
// IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.
//
// Lead Maintainer: Virgil Security Inc. <support@virgilsecurity.com>
//

import Foundation
import VirgilCryptoFoundation

// MARK: - Extension for working with streams
extension VirgilCrypto {
    /// Generates digital signature of data stream using private key
    ///
    /// - Note: Returned value contains only digital signature, not data itself.
    ///
    /// - Note: Data inside this function is guaranteed to be hashed with SHA512 at least one time.
    ///         It's secure to pass raw data here.
    ///
    /// - Parameters:
    ///   - stream: Data stream to sign
    ///   - privateKey: Private key used to generate signature
    /// - Returns: Digital signature
    /// - Throws: Rethrows from StreamSigner
    @objc open func generateStreamSignature(of stream: InputStream,
                                            using privateKey: VirgilPrivateKey) throws -> Data {
        guard let signHash = privateKey.privateKey as? SignHash else {
            throw VirgilCryptoError.keyDoesntSupportSigning
        }
        
        let signer = Signer()
        
        signer.setHash(hash: Sha512())
        
        signer.reset()
    
        if stream.streamStatus == .notOpen {
            stream.open()
        }
        
        while stream.hasBytesAvailable {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: VirgilCrypto.chunkSize)
            let actualReadLen = stream.read(buffer, maxLength: VirgilCrypto.chunkSize)
            defer {
                buffer.deallocate()
            }
            
            guard actualReadLen > 0 else {
                if actualReadLen < 0 {
                    throw VirgilCryptoError.inputStreamError
                }
                
                break
            }
            
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(buffer), count: actualReadLen, deallocator: Data.Deallocator.none)
            
            signer.update(data: data)
        }

        return try signer.sign(privateKey: signHash)
    }
    
    /// Verifies digital signature of data stream
    ///
    /// Note: Verification algorithm depends on PublicKey type. Default: EdDSA
    ///
    /// - Parameters:
    ///   - signature: Digital signature
    ///   - stream: Data stream that was signed
    ///   - publicKey: Signed public key
    /// - Returns: True if signature is verified, false otherwise
    @nonobjc open func verifyStreamSignature(_ signature: Data, of stream: InputStream,
                                          with publicKey: VirgilPublicKey) throws -> Bool {
        guard let verifyHash = publicKey.publicKey as? VerifyHash else {
            throw VirgilCryptoError.keyDoesntSupportSigning
        }
        
        let verifier = Verifier()
        
        try verifier.reset(signature: signature)
        
        if stream.streamStatus == .notOpen {
            stream.open()
        }
        
        while stream.hasBytesAvailable {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: VirgilCrypto.chunkSize)
            let actualReadLen = stream.read(buffer, maxLength: VirgilCrypto.chunkSize)
            defer {
                buffer.deallocate()
            }
            
            guard actualReadLen > 0 else {
                if actualReadLen < 0 {
                    throw VirgilCryptoError.inputStreamError
                }
                
                break
            }
            
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(buffer), count: actualReadLen, deallocator: Data.Deallocator.none)
            
            verifier.update(data: data)
        }
        
        return verifier.verify(publicKey: verifyHash)
    }

    /// Verifies digital signature of data
    ///
    /// - Note: Verification algorithm depends on PublicKey type. Default: EdDSA for ed25519 key
    ///
    /// - Parameters:
    ///   - signature: Digital signature
    ///   - data: Data that was signed
    ///   - publicKey: Signer public key
    /// - Returns: True if signature is verified, false otherwise
    @available(swift, obsoleted: 1.0)
    @objc open func verifyStreamSignature_objc(_ signature: Data, of stream: InputStream, with publicKey: VirgilPublicKey) -> Bool {
        return (try? self.verifyStreamSignature(signature, of: stream, with: publicKey)) ?? false
    }
    
    /// Encrypts data stream for passed PublicKeys
    ///
    /// 1. Generates random AES-256 KEY1
    /// 2. Encrypts data with KEY1 using AES-256-GCM
    /// 3. Generates ephemeral key pair for each recipient
    /// 4. Uses Diffie-Hellman to obtain shared secret with each recipient's public key & each ephemeral private key
    /// 5. Computes KDF to obtain AES-256 key from shared secret for each recipient
    /// 6. Encrypts KEY1 with this key using AES-256-CBC for each recipient
    ///
    /// - Parameters:
    ///   - stream: data Stream to be encrypted
    ///   - outputStream: Stream with encrypted data
    ///   - recipients: Recipients
    /// - Throws: Rethrows from ChunkCipher
    @objc open func encrypt(_ stream: InputStream, to outputStream: OutputStream,
                            for recipients: [VirgilPublicKey]) throws {
        let aesGcm = Aes256Gcm()
        let cipher = RecipientCipher()
        
        cipher.setEncryptionCipher(encryptionCipher: aesGcm)
        cipher.setRandom(random: self.rng)
        
        recipients.forEach {
            cipher.addKeyRecipient(recipientId: $0.identifier, publicKey: $0.publicKey)
        }
        
        try cipher.startEncryption()
        
        let msgInfo = cipher.packMessageInfo()
        
        var actualWriteLen = 0
        
        if outputStream.streamStatus == .notOpen {
            outputStream.open()
        }
        
        msgInfo.withUnsafeBytes { buffer in
            actualWriteLen = outputStream.write(buffer, maxLength: msgInfo.count)
        }
        
        guard actualWriteLen == msgInfo.count else {
            throw VirgilCryptoError.outputStreamError
        }

        if stream.streamStatus == .notOpen {
            stream.open()
        }
        
        while stream.hasBytesAvailable {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: VirgilCrypto.chunkSize)
            let actualReadLen = stream.read(buffer, maxLength: VirgilCrypto.chunkSize)
            defer {
                buffer.deallocate()
            }
            
            guard actualReadLen > 0 else {
                if actualReadLen < 0 {
                    throw VirgilCryptoError.inputStreamError
                }
                
                break
            }
            
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(buffer), count: actualReadLen, deallocator: Data.Deallocator.none)
            
            let chunk = try cipher.processEncryption(data: data)
            
            var actualWriteLen = 0
            chunk.withUnsafeBytes { buffer in
                actualWriteLen = outputStream.write(buffer, maxLength: chunk.count)
            }
            
            guard actualWriteLen == chunk.count else {
                throw VirgilCryptoError.outputStreamError
            }
        }
        
        let finish = try cipher.finishEncryption()
        
        finish.withUnsafeBytes { buffer in
            actualWriteLen = outputStream.write(buffer, maxLength: finish.count)
        }
        
        guard actualWriteLen == finish.count else {
            throw VirgilCryptoError.outputStreamError
        }
    }
    
    /// Decrypts data stream using passed PrivateKey
    ///
    /// 1. Uses Diffie-Hellman to obtain shared secret with sender ephemeral public key & recipient's private key
    /// 2. Computes KDF to obtain AES-256 KEY2 from shared secret
    /// 3. Decrypts KEY1 using AES-256-CBC
    /// 4. Decrypts data using KEY1 and AES-256-GCM
    //
    /// - Parameters:
    ///   - stream: Stream with encrypted data
    ///   - outputStream: Stream with decrypted data
    ///   - privateKey: Recipient's private key
    /// - Throws: Rethrows from ChunkCipher
    @objc open func decrypt(_ stream: InputStream, to outputStream: OutputStream,
                            with privateKey: VirgilPrivateKey) throws {
        
        let cipher = RecipientCipher()
        
        try cipher.startDecryptionWithKey(recipientId: privateKey.identifier,
                                          privateKey: privateKey.privateKey,
                                          messageInfo: Data())
        
        if stream.streamStatus == .notOpen {
            stream.open()
        }
        
        if outputStream.streamStatus == .notOpen {
            outputStream.open()
        }
        
        while stream.hasBytesAvailable {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: VirgilCrypto.chunkSize)
            let actualReadLen = stream.read(buffer, maxLength: VirgilCrypto.chunkSize)
            defer {
                buffer.deallocate()
            }
            
            guard actualReadLen > 0 else {
                if actualReadLen < 0 {
                    throw VirgilCryptoError.inputStreamError
                }
                
                break
            }
            
            let data = Data(bytesNoCopy: UnsafeMutableRawPointer(buffer), count: actualReadLen, deallocator: Data.Deallocator.none)
            
            let chunk = try cipher.processDecryption(data: data)
            
            var actualWriteLen = 0
            chunk.withUnsafeBytes { buffer in
                actualWriteLen = outputStream.write(buffer, maxLength: chunk.count)
            }
            
            guard actualWriteLen == chunk.count else {
                throw VirgilCryptoError.outputStreamError
            }
        }
        
        let finish = try cipher.finishDecryption()
        
        var actualWriteLen = 0
        
        finish.withUnsafeBytes { buffer in
            actualWriteLen = outputStream.write(buffer, maxLength: finish.count)
        }
        
        guard actualWriteLen == finish.count else {
            throw VirgilCryptoError.outputStreamError
        }
    }
}
