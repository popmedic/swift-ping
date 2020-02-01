//
//  Ping.swift
//  ping
//
//  Copyright © 2019. All rights reserved.
//

import Foundation

// MARK: - protocols
public protocol PingingDelegate: class {
    func pinging(_ pinging: Pinging,
                 didStart ipAddress: String,
                 with name: String)
    func pinging(_ pinging: Pinging,
                 didError error: Error)
    func pinging(_ pinging: Pinging,
                 didFinish ipAddress: String,
                 with name: String,
                 report: PingingReport)
    func pinging(_ pinging: Pinging,
                 didSend packet: Data?,
                 with sequence: Int,
                 at time: TimeInterval)
    func pinging(_ pinging: Pinging,
                 didRecv packet: Data?,
                 with sequence: Int,
                 at time: TimeInterval)
}

public protocol Pinging {
    var delegate: PingingDelegate? { get set }
    func start(host name: String, echo message: String)
    func finish()
}

public struct PingingReport {
    let failures: Int
    let misses: Int
    let latencies: [TimeInterval]
    let jitters: [TimeInterval]
    
    var averageLatency: Double {
        var sum = 0.0
        latencies.forEach { sum += $0 }
        return sum / Double(latencies.count)
    }
    var averageJitter: Double {
        var sum = 0.0
        jitters.forEach{ sum += $0 }
        return sum / Double(jitters.count)
    }
}

extension PingingReport: CustomStringConvertible {
    public var description: String {
        return
            latency +
            jitter +
            "\n---------------:" +
            "\naverage latency: \(averageLatency) secs" +
            "\naverage jitter: \(averageJitter) secs" +
            "\nmisses: \(misses)" +
            "\nfailures: \(failures)\n"
    }
    
    private var latency: String {
        return getString(prefix: "\nlatencies:\n----------\n", for: latencies)
    }
    
    private var jitter: String {
        return getString(prefix: "\njitters:\n--------\n", for: jitters, seqout: { "\($0+1)-\($0+2)" })
    }
    
    private func getString(prefix: String = "",
                           for: [Double],
                           seqout: ((Int) -> String) = { "\($0+1)" }) -> String {
        var out = prefix
        for (i, val) in `for`.enumerated() {
            out += "seq \(seqout(i)): \(val) secs\n"
        }
        return out
    }
}

// MARK: - implementation
final public class Ping: Pinging {
    // MARK: - private constants
    private let minPacketSize = MemoryLayout<IPv4Header>.size + MemoryLayout<ICMPHeader>.size
    private let usingFamily: sa_family_t
    private let usingWait: TimeInterval
    private let usingTTL: TimeInterval
    
    // MARK: variables
    public weak var delegate: PingingDelegate?
    public var isRunning: Bool { return identifier != 0 }
    
    // MARK: control functions
    public func start(host name: String,
               echo message: String) {
        let `continue`: Bool = access.sync {
            guard !isRunning else {
                delegate?.pinging(self, didError: Error.alreadyRunning)
                return false
            }
            identifier = UInt16.random(in: 1..<UInt16.max)
            self.name = name
            self.message = message
            return true
        }
        guard `continue` else { return }
        access.async(flags: [.barrier]) {
            self.resolve(host: name, for: self.usingFamily) { (data, error) in
                guard error == nil else {
                    self.delegate?.pinging(self, didError: error!)
                    self.finish()
                    return
                }
                guard let data = data else {
                    self.delegate?.pinging(self, didError: HostError.unableToReadData)
                    self.finish()
                    return
                }
                self.host = data
                self.setupSocket()
                self.send(sequence: 1)
            }
        }
    }
    
    public func finish() {
        access.async(flags: [.barrier]) {
            guard self.isRunning else { return }
            
            self.delegate?.pinging(self,
                                   didFinish: self.host == nil ? "" : self.ipAddress(from: self.host!),
                                   with: self.name,
                                   report: PingingReport(failures: self.failures,
                                                         misses: self.misses,
                                                         latencies: self.latencies,
                                                         jitters: self.jitters))
            // clean up
            self.ttlWorkItems.forEach { $0.value.cancel() }
            self.ttlWorkItems.removeAll()
            self.host = nil
            if self.socket != nil {
                CFSocketInvalidate(self.socket!)
                self.socket = nil
            }
            if self.runLoopSource != nil {
                CFRunLoopSourceInvalidate(self.runLoopSource)
                self.runLoopSource = nil
            }
            self.identifier = 0
            self.name = ""
            self.message = nil
            self.startTimes.removeAll()
            self.jitters.removeAll()
            self.latencies.removeAll()
            self.failures = 0
            self.misses = 0
            self.sequenceNumber = 0
        }
    }
    
    // MARK private variables
    /// a serial queue for serializing all access.
    private var access = DispatchQueue(label: "ping access queue",
                                       qos: .userInteractive,
                                       attributes: [.concurrent],
                                       autoreleaseFrequency: .workItem,
                                       target: nil)
    /// a serial queue used to for the ping reads,
    /// the socket is attached the the runloop of this queue
    private var process = DispatchQueue(label: "ping runner queue",
                                        qos: .userInteractive,
                                        attributes: [],
                                        autoreleaseFrequency: .workItem,
                                        target: nil)
    private var identifier: UInt16 = 0
    private var host: Data?
    private var socket: CFSocket?
    private var runLoopSource: CFRunLoopSource?
    private var name: String = ""
    private var message: String?
    private var startTimes = [UInt16: TimeInterval]()
    private var jitters = [TimeInterval]()
    private var latencies = [TimeInterval]()
    private var failures: Int = 0
    private var misses: Int = 0
    private var sequenceNumber: UInt16 = 0
    private var ttlWorkItems = [UInt16: DispatchWorkItem]()
    
    public init(usingFamily: sa_family_t = sa_family_t(AF_INET),
         usingWait: TimeInterval = 0.0,
         usingTTL: TimeInterval = 5.0) {
        self.usingFamily = usingFamily
        self.usingWait = usingWait
        self.usingTTL = usingTTL
    }
}

private extension Ping {
    // MARK: - resolve and setup
    typealias ResolvingCompletion = (_ sockAddr: Data?, _ error: Swift.Error?) -> Void
    func resolve(host name: String,
                 for family: sa_family_t,
                 completion handler: @escaping ResolvingCompletion) {
        
        guard let cname = name.cString(using: .ascii) else {
            handler(nil, HostError.unableToResolveAddr)
            return
        }
        var res: UnsafeMutablePointer<addrinfo>?
        let n = getaddrinfo(cname, nil, nil, &res)
        defer {
            freeaddrinfo(res)
        }
        guard n == 0 else {
            handler(nil, HostError.unableToResolveAddr)
            return
        }
        
        while res?.pointee.ai_next != nil {
            guard let addr = res?.pointee.ai_addr else { continue }
            if addr.pointee.sa_family == family {
                handler(Data(bytes: addr, count: Int(addr.pointee.sa_len)), nil)
                return
            }
            res = res?.pointee.ai_next
        }
        handler(nil, HostError.unableToFindSuitableAddr)
        return
    }
    
    func setupSocket() {
        do {
            guard host != nil else { throw Error.nilHostOnSetupSocket }
            let family = self.family(from: host!)
            var context = CFSocketContext(version: 0,
                                          info: Unmanaged.passRetained(self).toOpaque(),
                                          retain: nil,
                                          release: nil,
                                          copyDescription: nil)
            self.socket = CFSocketCreate(kCFAllocatorDefault, Int32(family), SOCK_DGRAM,
                                         family == AF_INET6 ? IPPROTO_ICMPV6 : IPPROTO_ICMP,
                                         CFSocketCallBackType.dataCallBack.rawValue,
                                         readCallout,
                                         &context)
            runLoopSource = CFSocketCreateRunLoopSource(nil, self.socket, 0);
            guard runLoopSource != nil else { throw Error.unableToCreateRunLoopSource }
            process.async {
                guard let runLoopSource = self.runLoopSource else { return }
                CFRunLoopAddSource(CFRunLoopGetCurrent(),
                                   runLoopSource,
                                   CFRunLoopMode.commonModes)
                RunLoop.current.run()
            }
            delegate?.pinging(self, didStart: self.ipAddress(from: host!), with: name)
        } catch {
            delegate?.pinging(self, didError: error)
            finish()
        }
    }
    
    // MARK: - recv
    func readData(from socket: CFSocket?, with packet: Data) {
        access.sync {
            do {
                let endTime = CFAbsoluteTimeGetCurrent()
                guard socket != nil else { throw Error.nilSocketOnReadData }
                guard packet.count > 0 else { throw Warning.readDataHasNoData }
                let sequence: UInt16 = try validate(packet: packet)
                if let ttlWorkItem = ttlWorkItems[sequence] {
                    ttlWorkItem.cancel()
                    ttlWorkItems.removeValue(forKey: sequence)
                }
                guard let startTime = startTimes[sequence] else { throw Error.startTimeDoesNotExist }
                let latency = endTime - startTime
                if latencies.count > 0 {
                    jitters.append(abs(latencies.last! - latency))
                }
                latencies.append(latency)
                startTimes.removeValue(forKey: sequence)
                delegate?.pinging(self, didRecv: packet, with: Int(sequence), at: endTime)
                access.asyncAfter(deadline: DispatchTime.now() + usingWait, flags: [.barrier]) {
                    self.send(sequence: self.sequenceNumber + 1)
                }
            } catch {
                failures += 1
                delegate?.pinging(self, didError: error)
            }
        }
    }
    
    // MARK: recv helpers
    func validate(packet: Data) throws -> UInt16 {
        guard host != nil else { failures += 1; throw Error.nilHostOnReadData }
        let family = self.family(from: host!)
        switch Int32(family) {
        case AF_INET: return try validateIPv4Response(packet: packet)
        case AF_INET6:return try validateIPv6Response(packet: packet)
        default: throw Error.unknownFamilyOnReadData
        }
    }
    
    func validateIPv4Response(packet: Data) throws -> UInt16 {
        guard packet.count >= minPacketSize else {
            throw Warning.invalidIPv4Packet
        }
        let offset = try icmpHeaderOffset(in: packet)
        var icmpHeaderData = packet.subdata(in: offset..<packet.count)
        let icmpHeader: ICMPHeader = icmpHeaderData.withUnsafeBytes {
            $0.load(as: ICMPHeader.self)
        }
        let recvChecksum = icmpHeader.checksum
        var newChecksum: UInt16 = 0
        icmpHeaderData.replaceSubrange(2..<(2+MemoryLayout<UInt16>.size),
                                       with: &newChecksum,
                                       count: MemoryLayout<UInt16>.size)
        let bytes = NSMutableData(data: icmpHeaderData).mutableBytes
        let calcChecksum = checksum(bytes,
                                    length: packet.count - offset)
        guard recvChecksum == calcChecksum else { throw Warning.checksumDoesNotMatch }
        
        guard
            icmpHeader.type == ICMPEchoType.icmp4Response.rawValue,
            identifier == icmpHeader.identifier,
            sequenceNumber <= icmpHeader.sequenceNumber
        else { throw Warning.invalidIPv4Packet }
        return icmpHeader.sequenceNumber
    }
    
    func validateIPv6Response(packet: Data) throws -> UInt16 {
        guard packet.count >= MemoryLayout<ICMPHeader>.size else {
            throw Warning.invalidIPv6Packet
        }
        let icmpHeader = self.icmpHeader(from: packet)
        guard
            icmpHeader.identifier == identifier,
            icmpHeader.code == 0,
            icmpHeader.type == ICMPEchoType.icmp6Response.rawValue,
            sequenceNumber <= icmpHeader.sequenceNumber
        else { throw Warning.invalidIPv6Packet }
        return icmpHeader.sequenceNumber
    }
    
    func icmpHeaderOffset(in packet: Data) throws -> Int {
        let minPacketSize = MemoryLayout<IPv4Header>.size + MemoryLayout<ICMPHeader>.size
        guard packet.count >= minPacketSize else {
            throw Warning.invalidIPv4PacketToSmall
        }
        let ipv4HeaderSize = MemoryLayout<IPv4Header>.size
        let ipHeader = packet[0..<ipv4HeaderSize].withUnsafeBytes {
            $0.load(as: IPv4Header.self)
        }
        guard
            (ipHeader.versionAndHeaderLength & 0xF0) == 0x40,
            ipHeader.protocol == IPPROTO_ICMP
        else {
            throw Warning.invalidIPv4Packet
        }
        let headerLength = Int(ipHeader.versionAndHeaderLength & 0x0F) * MemoryLayout<UInt32>.size
        guard packet.count > Int(headerLength) + MemoryLayout<ICMPHeader>.size else {
            throw Warning.invalidIPv4Packet
        }
        return headerLength
    }
    
    // MARK: - send
    func send(sequence: UInt16) {
        sequenceNumber = sequence
        do {
            guard isRunning else { return }
            guard host != nil else { throw Error.nilHostOnSend }
            guard socket != nil else { throw Error.nilSocketOnSent }
            guard message != nil else { throw Error.nilMessageOnSend }
            guard let payload = message!.data(using: .ascii) else { throw Error.noPayloadOnSend }
            let type: ICMPEchoType = family(from: host!) == AF_INET ? .icmp4Request : .icmp6Request
            let packet = try self.packet(with: type, payload: payload)
            let startTime = CFAbsoluteTimeGetCurrent()
            startTimes[sequenceNumber] = startTime
            let success = CFSocketSendData(socket!, host! as CFData,
                                           packet as CFData, usingTTL)
            switch success {
            case .success: break
            case .error: throw Error.unableToSend
            case .timeout: throw Warning.sendTimedOut
            default: throw Error.unknownSendError
            }
            let ttlWorkItem = DispatchWorkItem(block: { [weak self] in
                guard let `self` = self else { return }
                self.access.async(flags: [.barrier]) {
                    self.misses += 1
                    self.delegate?.pinging(self, didError: Warning.sendTimedOut)
                    self.send(sequence: self.sequenceNumber)
                }
            })
            ttlWorkItems[sequenceNumber] = ttlWorkItem
            access.asyncAfter(deadline: .now() + usingTTL, execute: ttlWorkItem)
            delegate?.pinging(self, didSend: packet, with: Int(sequenceNumber),
                              at: startTime)
        } catch let error where error is Warning {
            delegate?.pinging(self, didError: error)
        } catch {
            delegate?.pinging(self, didError: error)
            finish()
        }
    }
    
    // MARK: send helpers
    func packet(with type: ICMPEchoType, payload: Data) throws -> Data {
        var header = ICMPHeader()
        let packetSize = MemoryLayout<ICMPHeader>.size + payload.count
        var packet = Data(repeating: 0, count: packetSize)
        header.type = UInt8(type.rawValue)
        header.code = 0
        header.checksum = 0
        header.identifier = identifier
        header.sequenceNumber = sequenceNumber
        packet.replaceSubrange(0..<MemoryLayout<ICMPHeader>.size, with: &header,
                               count: MemoryLayout<ICMPHeader>.size)
        packet.replaceSubrange(MemoryLayout<ICMPHeader>.size..<packetSize, with: payload)
        if type == .icmp4Request || type == .icmp4Response {
            let bytes = NSMutableData(data: packet).mutableBytes
            var checksum = self.checksum(bytes, length: packet.count)
            packet.replaceSubrange(2..<(2+MemoryLayout<UInt16>.size), with: &checksum,
                                   count: MemoryLayout<UInt16>.size)
        }
        return packet
    }
    
    func ipAddress(from data: Data) -> String {
        var sa: sockaddr = sockAddr(from: data)
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let res = getnameinfo(&sa, socklen_t(sa.sa_len), &buf,
                                 socklen_t(buf.count), nil, socklen_t(0), NI_NUMERICHOST)
        return res == 0 ? String(cString: buf) : "unknown"
    }
    
    func sockAddr(from data: Data) -> sockaddr {
        data.withUnsafeBytes {
            $0.load(as: sockaddr.self)
        }
    }
    
    func icmpHeader(from data: Data) -> ICMPHeader {
        data.withUnsafeBytes {
            $0.load(as: ICMPHeader.self)
        }
    }
    
    func family(from host: Data) -> sa_family_t {
        sockAddr(from: host).sa_family
    }
    
    func checksum(_ bytes: UnsafeMutableRawPointer, length: Int) -> UInt16 {
        var n = length
        var sum: UInt32 = 0
        var buf = bytes.assumingMemoryBound(to: UInt16.self)
        
        while n > 1 {
            sum += UInt32(buf.pointee)
            buf = buf.successor()
            n -= MemoryLayout<UInt16>.size
        }
        if n == 1 {
            sum += UInt32(UnsafeMutablePointer<UInt16>(buf).pointee)
        }
        sum = (sum >> 16) + (sum & 0xFFFF)
        sum += sum >> 16
        guard sum < UInt16.max else { return 0 }
        return ~UInt16(sum)
    }
}

// MARK: - errors
extension Ping {
    enum HostError: Swift.Error {
        case unableToResolveAddr
        case unableToFindSuitableAddr
        case unableToReadData
    }
    
    enum Warning: Swift.Error {
        case sendTimedOut
        case invalidIPv4Packet
        case invalidIPv4PacketToSmall
        case invalidIPv6Packet
        case checksumDoesNotMatch
        case readDataHasNoData
    }
    
    enum Error: Swift.Error {
        case messageToLarge
        case alreadyRunning
        case nilHostOnSetupSocket
        case unableToCreateRunLoopSource
        case lostSelfOnSetupSocket
        case nilHostOnReadData
        case nilSocketOnReadData
        case unknownFamilyOnReadData
        case nilHostOnPacket
        case startTimeDoesNotExist
        case nilHostOnSend
        case nilMessageOnSend
        case noPayloadOnSend
        case nilSocketOnSent
        case unableToSend
        case unknownSendError
    }
}

// MARK: - headers
private extension Ping {
    struct IPv4Header {
        var versionAndHeaderLength: UInt8
        var differentiatedServices: UInt8
        var totalLength: UInt16
        var identification: UInt16
        var flagsAndFragmentOffset: UInt16
        var timeToLive: UInt8
        var `protocol`: UInt8
    }
}

private extension Ping {
    struct ICMPHeader {
        var type: UInt8 = 0
        var code: UInt8 = 0
        var checksum: UInt16 = 0
        var identifier: UInt16 = 0
        var sequenceNumber: UInt16 = 0
    }
    
    enum ICMPEchoType: UInt8 {
        case icmp4Request = 8
        case icmp4Response = 0
        case icmp6Request = 128
        case icmp6Response = 129
    }
}

// MARK: - socket read callout
fileprivate func readCallout(_ socket: CFSocket?,
                             _ type: CFSocketCallBackType,
                             _ address: CFData?,
                             _ data: UnsafeRawPointer?,
                             _ info: UnsafeMutableRawPointer?) -> Void {
    
    guard let info = info else { fatalError("lost self on setup socket") }
    // get the ping instance from the info context.
    var ping: Ping! = Unmanaged.fromOpaque(info).takeUnretainedValue()
    if (type as CFSocketCallBackType) == CFSocketCallBackType.dataCallBack, let ptr = data {
        let packet = Unmanaged<NSData>.fromOpaque(ptr).takeUnretainedValue() as Data
        ping.readData(from: socket, with: packet)
    }
    ping = nil
}
