import CoreGraphics
import Foundation

/// Measures `SceneSignature.change`, the number that decides when a frame is kept and when the
/// language model is asked something while watching.
///
///   eyes-cli scene a.jpg b.jpg [c.jpg ...]     change between each image and the one before it
///   eyes-cli scene --pairs pairs.tsv           one `a  b  [note]` per line; prints change per pair
///   eyes-cli scene --clip clip.mov [--fps 10] [--lag 1.5]   change from frame to frame, from the clip's first frame,
///                                              and from the frame `lag` seconds earlier
func runSceneMode(_ arguments: [String]) {
    var args = arguments
    func signature(_ path: String) -> SceneSignature? {
        loadPixelBuffer(path).flatMap { SceneSignature($0) }
    }
    if args.first == "--pairs", args.count >= 2 {
        guard let text = try? String(contentsOfFile: args[1], encoding: .utf8) else { print("could not read \(args[1])"); return }
        let folder = URL(fileURLWithPath: args[1]).deletingLastPathComponent()
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 2 else { continue }
            guard let a = signature(URL(fileURLWithPath: fields[0], relativeTo: folder).path),
                  let b = signature(URL(fileURLWithPath: fields[1], relativeTo: folder).path)
            else { print("?\t\(line)"); continue }
            print(String(format: "%.3f\t%@", b.change(from: a), String(line)))
        }
        return
    }
    if args.first == "--clip", args.count >= 2 {
        var fps = 10.0
        if let i = args.firstIndex(of: "--fps"), i + 1 < args.count { fps = Double(args[i + 1]) ?? fps }
        guard let clip = VideoClip(path: args[1]) else { print("could not open \(args[1])"); return }
        // How far back the third column looks: the gap between one watch check and the next.
        var lag = 1.5
        if let i = args.firstIndex(of: "--lag"), i + 1 < args.count { lag = Double(args[i + 1]) ?? lag }
        var seen: [SceneSignature] = []
        var time = 0.0
        print("seconds\tfrom previous\tfrom first\tfrom \(lag) s earlier")
        while time <= clip.duration {
            if let frame = clip.frame(at: time).flatMap(PixelWarp.pixelBuffer(from:)), let now = SceneSignature(frame) {
                let earlier = seen.count - Int((lag * fps).rounded())
                print(String(format: "%.1f\t%.3f\t%.3f\t%.3f", time, seen.last.map { now.change(from: $0) } ?? 0,
                             seen.first.map { now.change(from: $0) } ?? 0, earlier >= 0 ? now.change(from: seen[earlier]) : 0))
                seen.append(now)
            }
            time += 1 / fps
        }
        return
    }
    guard args.count >= 2 else {
        print("usage: eyes-cli scene a.jpg b.jpg ... | --pairs pairs.tsv | --clip clip.mov [--fps 10]")
        return
    }
    var previous = signature(args.removeFirst())
    for path in args {
        let now = signature(path)
        if let now, let previous { print(String(format: "%.3f\t%@", now.change(from: previous), (path as NSString).lastPathComponent)) }
        previous = now
    }
}
