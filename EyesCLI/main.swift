// Mac test harness: runs the same code as the app against files, one mode per source file.
//
//   eyes-cli ask <model.gguf> <mmproj.gguf> [flags] <image> <question> ...    LFM3-VL answers
//   eyes-cli video <model.gguf> <mmproj.gguf> [flags] <clip> <question> ...   LFM3-VL answers about a short clip
//   eyes-cli check <model.gguf> <mmproj.gguf> [flags] --batch checks.tsv       the yes/no check watch mode rests on
//   eyes-cli watch <model.gguf> <mmproj.gguf> [flags] <clip> <condition> ...   a model-judged search replayed on a clip
//   eyes-cli find <arcface> <dinov3> <yoloe> <labels> <turns dir> [flags]      a memory-judged search replayed on saved turns
//   eyes-cli soak <model.gguf> <mmproj.gguf> [--minutes 10] <clip> <condition> <question>   memory over a long run
//   eyes-cli scene a.jpg b.jpg ... | --clip clip.mov                         how much the scene changed between frames
//   eyes-cli detect <yoloe26m.mlpackage> <yoloe_labels.json> <image> ...      object detector
//   eyes-cli safety "question" ...                                            safety routing, replies
//   eyes-cli describe <mlpackage> <labels> <model.gguf> <mmproj.gguf> <image> ... tap description
//   eyes-cli read <image> ...                                                 Apple's text recogniser
//   eyes-cli sharp <image> ...                                                sharpness score of each frame
//   eyes-cli faces ...                                                        face recognition
//   eyes-cli things ...                                                       belonging matching
//   eyes-cli belongings <dinov3> <yoloe> <labels> <photos dir>                belonging memory end to end
//   eyes-cli proximity ...                                                    proximity haptics logic
//   eyes-cli commands ...                                                     voice command parsing

import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let rest = Array(arguments.dropFirst())
switch arguments.first {
case "ask": runAskMode(rest)
case "video": runVideoMode(rest)
case "check": runCheckMode(rest)
case "watch": runWatchMode(rest)
case "find": runFindMode(rest)
case "soak": runSoakMode(rest)
case "scene": runSceneMode(rest)
case "detect": runDetectMode(rest)
case "safety": runSafetyMode(rest)
case "describe": runDescribeMode(rest)
case "read": runReadMode(rest)
case "sharp": runSharpMode(rest)
case "faces": runFacesMode(rest)
case "things": runThingsMode(rest)
case "belongings": runBelongingsMode(rest)
case "proximity": runProximityMode(rest)
case "commands": runCommandsMode(rest)
default: print("usage: eyes-cli <ask|detect|safety|describe|read|sharp|faces|things|belongings|proximity|commands> ...  (see EyesCLI/main.swift)")
}
