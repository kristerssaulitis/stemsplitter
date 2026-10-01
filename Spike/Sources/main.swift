import Foundation

// Day-1 benchmark spike CLI (plan T1/TE2, eng E3) — implementation in SpikeHarness.swift.
//
//   spike <corpus-dir> [--out <dir>]   full shipping-path pipeline run over the corpus
//   spike gen <dir> [--seconds 30,90,180]
//                                      synthetic stereo AAC corpus for plumbing runs
//   spike help

exit(await SpikeHarness.run(arguments: CommandLine.arguments))
