import Foundation
import ping

#if os(OSX)
class PingDelegate: PingingDelegate {
    var name: String = ""
    var ipAddress: String = ""
    var startTime: TimeInterval = 0.0
    func pinging(_ pinging: Pinging, didStart ipAddress: String, with name: String) {
        print("📡 Pinging \(name) (\(ipAddress))")
        self.name = name
        self.ipAddress = ipAddress
    }
    
    func pinging(_ pinging: Pinging, didError error: Error) {
        print("💩 - \(error)")
    }
    
    func pinging(_ pinging: Pinging, didFinish ipAddress: String, with name: String, report: PingingReport) {
        print("\(report)")
        exit(0)
    }
    
    func pinging(_ pinging: Pinging, didSend packet: Data?, with sequence: Int, at time: TimeInterval) {
        startTime = time
    }
    
    func pinging(_ pinging: Pinging, didRecv packet: Data?, with sequence: Int, at time: TimeInterval) {
        print("📥 recv \(packet?.count ?? 0) bytes from \(name) (\(ipAddress)) seq: \(sequence) took \((time-startTime)*1000) ms")
    }
}

guard
    CommandLine.arguments.count > 1,
    let hostname = CommandLine.arguments.last
else {
    print("\nUSAGE: ping <hostname>\n\nno hostname given\nexample:\n\tping popmedic.com\n")
    exit(1)
}

var ping = Ping()
let pingObserver = PingDelegate()
ping.delegate = pingObserver
ping.start(host: hostname, echo: "abcdefghijklmnopqrstuvwxyzabcdefghij")

signal(SIGINT, SIG_IGN)

let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSrc.setEventHandler {
    ping.finish()
}
sigintSrc.resume()

RunLoop.main.run()
#endif
