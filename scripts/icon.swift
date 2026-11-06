import AppKit
let output=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Activity.iconset")
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
for size in [16,32,128,256,512] {
    for scale in [1,2] {
        let pixels=size*scale
        let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:pixels,pixelsHigh:pixels,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
        let context=NSGraphicsContext.current!.cgContext; context.scaleBy(x:CGFloat(pixels)/512,y:CGFloat(pixels)/512)
        NSColor(white:0.16,alpha:1).setFill(); NSBezierPath(roundedRect:NSRect(x:36,y:36,width:440,height:440),xRadius:103,yRadius:103).fill()
        NSColor(white:0.98,alpha:1).setFill(); NSBezierPath(roundedRect:NSRect(x:173,y:105,width:166,height:302),xRadius:27,yRadius:27).fill()
        for y in [166.0,247.0,328.0] {
            NSColor(white:0.25,alpha:1).setFill(); NSBezierPath(ovalIn:NSRect(x:194,y:y,width:12,height:12)).fill()
            NSColor(white:0.25,alpha:0.75).setFill(); NSBezierPath(roundedRect:NSRect(x:220,y:y+3,width:91,height:7),xRadius:3,yRadius:3).fill()
            NSColor(white:0.25,alpha:0.25).setFill(); NSBezierPath(roundedRect:NSRect(x:220,y:y-13,width:64,height:5),xRadius:2,yRadius:2).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix=scale==2 ? "@2x" : ""
        try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
