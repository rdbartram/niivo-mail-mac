import Foundation
import ProtectedContent

@MainActor func runRTFBodyTests() {
    section("Protected RTF bodies (MS-OXRTFCP / MS-OXRTFEX)")
    // MS-OXRTFCP §4.1 example: compressed "{\rtf1\ansi\ansicpg1252\pard hello world}\r\n".
    let comp: [UInt8] = [0x2d,0x00,0x00,0x00,0x2b,0x00,0x00,0x00,0x4c,0x5a,0x46,0x75,0xf1,0xc5,0xc7,0xa7,
                         0x03,0x00,0x0a,0x00,0x72,0x63,0x70,0x67,0x31,0x32,0x35,0x42,0x32,0x0a,0xf3,0x20,
                         0x68,0x65,0x6c,0x09,0x00,0x20,0x62,0x77,0x05,0xb0,0x6c,0x64,0x7d,0x0a,0x80,0x0f,0xa0]
    let raw = String(decoding: RTFBody.decompressIfNeeded(Data(comp)), as: UTF8.self)
    check(raw == "{\\rtf1\\ansi\\ansicpg1252\\pard hello world}\r\n", "LZFu decompression matches the spec example")

    let enc = #"""
    {\rtf1\ansi\ansicpg1252\fromhtml1 \deff0{\fonttbl{\f0\fswiss Arial;}}
    {\*\htmltag19 <html>}{\*\htmltag50 <body>}\htmlrtf {\htmlrtf0 {\*\htmltag64 <p>}Gr\'fc\'dfe \{x\}\htmlrtf\par\htmlrtf0{\*\htmltag72 </p>}}\htmlrtf}\htmlrtf0
    {\*\htmltag58 </body>}{\*\htmltag27 </html>}}
    """#
    let html = RTFBody.html(from: Data(enc.utf8))
    check(html.contains("<p>Grüße {x}") && html.contains("</p>") && html.contains("<body>") && !html.contains("Arial"),
          "HTML-encapsulated RTF de-encapsulates (htmltag kept, htmlrtf dropped, \\'hh via codepage)")

    let plain = RTFBody.html(from: Data(#"{\rtf1\ansi Hello \b bold\b0 world}"#.utf8))
    check(plain.contains("Hello") && plain.contains("world"), "plain RTF converts through AppKit")
}
