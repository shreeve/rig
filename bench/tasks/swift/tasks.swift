// bench/tasks's Swift twin, for the memory row of bench/tasks/bench-scale:
// run as `tasks-swift many [long]` it holds 10,000 tasks asleep at once in
// a task group, and as `tasks-swift idle [long]` none, sleeping as long.
// `long` sleeps 1 s, long enough for bench-scale to read the memory from
// outside. Prints `NAME NS CHECK`. Swift's cooperative pool sizes itself
// to the machine, so it takes no worker count and has no scaling rows.
import Foundation

let many = 10000

@main struct TasksSwift {
    static func main() async {
        let args = CommandLine.arguments
        guard args.count > 1 else {
            print("usage: tasks-swift many|idle [long]")
            return
        }
        let nap: UInt64 = (args.count > 2 && args[2] == "long") ? 1_000_000_000 : 200_000_000
        let start = DispatchTime.now().uptimeNanoseconds
        if args[1] == "many" {
            let sum = await withTaskGroup(of: Int.self) { group -> Int in
                for _ in 0..<many {
                    group.addTask {
                        try? await Task.sleep(nanoseconds: nap)
                        return 1
                    }
                }
                var total = 0
                for await x in group { total += x }
                return total
            }
            print("many", DispatchTime.now().uptimeNanoseconds - start, sum)
        } else {
            try? await Task.sleep(nanoseconds: nap)
            print("idle", DispatchTime.now().uptimeNanoseconds - start, 1)
        }
    }
}
