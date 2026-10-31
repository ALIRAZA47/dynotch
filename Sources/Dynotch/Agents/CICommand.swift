import Foundation

/// `dynotch ci`: starts watching the run for this branch.
enum CICommand {
    static func run(_ arguments: [String], _ socket: SocketClient, _ io: CommandLineClient.IO) -> Int32 { 0 }
}
