#!/usr/bin/env swift

import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: make_icns.swift ICONSET_DIRECTORY OUTPUT.icns\n", stderr)
    exit(2)
}

let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
let resources: [(type: String, file: String)] = [
    ("icp4", "icon_16x16.png"),
    ("icp5", "icon_32x32.png"),
    ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"),
    ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png")
]

func appendFourCC(_ value: String, to data: inout Data) {
    data.append(contentsOf: value.utf8)
}

func appendBigEndian(_ value: UInt32, to data: inout Data) {
    var bigEndian = value.bigEndian
    Swift.withUnsafeBytes(of: &bigEndian) {
        data.append(contentsOf: $0)
    }
}

var body = Data()
for resource in resources {
    let sourceURL = iconsetURL.appendingPathComponent(resource.file)
    let imageData = try Data(contentsOf: sourceURL)
    appendFourCC(resource.type, to: &body)
    appendBigEndian(UInt32(imageData.count + 8), to: &body)
    body.append(imageData)
}

var file = Data()
appendFourCC("icns", to: &file)
appendBigEndian(UInt32(body.count + 8), to: &file)
file.append(body)
try file.write(to: outputURL, options: .atomic)
