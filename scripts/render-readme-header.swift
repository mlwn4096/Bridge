// Run from the repository root: swift -module-cache-path /tmp/bridge-header-cache scripts/render-readme-header.swift
// Original typography artwork, rendered with AppKit and the existing Bridge icon.
import AppKit
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
for mobile in [false, true] {
 for dark in [true, false] {
  let width = mobile ? 780 : 1600, height = mobile ? 650 : 500
  let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
  let cg = NSGraphicsContext.current!.cgContext
  // Keep the canvas transparent so GitHub's light, dark and dimmed themes
  // show through without a rectangular background edge.
  cg.clear(CGRect(x:0,y:0,width:width,height:height))
  let center = CGFloat(width)/2
  let primary = dark ? NSColor(calibratedWhite:0.96,alpha:1) : NSColor(calibratedWhite:0.10,alpha:1)
  let secondary = dark ? NSColor(calibratedRed:0.68,green:0.73,blue:0.78,alpha:1) : NSColor(calibratedRed:0.33,green:0.38,blue:0.43,alpha:1)
  // The glow fades to transparent before reaching the canvas edges.
  for (offset,r,g,b) in [(-100.0,0.25,0.48,0.96),(120.0,0.33,0.72,0.56)] {
   cg.saveGState(); cg.translateBy(x:center+(mobile ? offset * 0.6 : offset),y:mobile ? 235 : 195); cg.scaleBy(x:mobile ? 260 : 425,y:mobile ? 230 : 190)
   let colors = [CGColor(red:r,green:g,blue:b,alpha:dark ? 0.11 : 0.08),CGColor(red:r,green:g,blue:b,alpha:0)] as CFArray
   cg.drawRadialGradient(CGGradient(colorsSpace:CGColorSpaceCreateDeviceRGB(),colors:colors,locations:[0,1])!,startCenter:.zero,startRadius:0,endCenter:.zero,endRadius:1,options:[])
   cg.restoreGState()
  }
  func label(_ text:String, x:CGFloat? = nil, y:CGFloat, size:CGFloat, weight:NSFont.Weight = .regular, color:NSColor? = nil) {
   let line=NSAttributedString(string:text,attributes:[.font:NSFont.systemFont(ofSize:size,weight:weight),.foregroundColor:color ?? primary])
   line.draw(at:NSPoint(x:x ?? (CGFloat(width)-line.size().width)/2,y:y))
  }
  let brandY:CGFloat = mobile ? 486 : 352
  NSImage(contentsOf:root.appendingPathComponent("mac/Resources/BridgeAppIcon.png"))!.draw(in:NSRect(x:center-147,y:brandY,width:88,height:88))
  label("Bridge",x:center-35,y:brandY+3,size:64,weight:.semibold)
  if mobile {
   label("Your Mac and Android,",y:365,size:48,weight:.medium)
   label("on speaking terms.",y:304,size:48,weight:.medium)
   label("Send a file. Share a thought.",y:224,size:30,color:secondary)
   label("Leave your phone in your pocket.",y:180,size:30,color:secondary)
  } else {
   label("Your Mac and Android, on speaking terms.",y:239,size:48,weight:.medium)
   label("Send a file. Share a thought. Leave your phone in your pocket.",y:180,size:30,color:secondary)
  }
  let pillY:CGFloat = mobile ? 67 : 65
  for (offset,title,symbol,green) in [(-174.0,"macOS","laptopcomputer",false),(34.0,"Android","smartphone",true)] {
   let rect=NSRect(x:center+offset,y:pillY,width:140,height:52)
   (green ? (dark ? NSColor(calibratedRed:0.14,green:0.23,blue:0.19,alpha:1) : NSColor(calibratedRed:0.89,green:0.95,blue:0.90,alpha:1)) : (dark ? NSColor(calibratedRed:0.16,green:0.20,blue:0.26,alpha:1) : NSColor(calibratedRed:0.91,green:0.94,blue:0.98,alpha:1))).setFill()
   NSBezierPath(roundedRect:rect,xRadius:26,yRadius:26).fill()
   let icon=NSImage(systemSymbolName:symbol,accessibilityDescription:nil)!.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize:22,weight:.medium))!
   let tinted=NSImage(size:icon.size,flipped:false) { bounds in
    primary.setFill(); bounds.fill(); icon.draw(in:bounds,from:.zero,operation:.destinationIn,fraction:1); return true
   }
   tinted.draw(in:NSRect(x:rect.minX+18,y:pillY+15,width:24,height:22))
   label(title,x:rect.minX+51,y:pillY+13,size:22,weight:.medium)
  }
  secondary.withAlphaComponent(0.5).setStroke()
  let line=NSBezierPath(); line.lineWidth=1.5; line.move(to:NSPoint(x:center-20,y:pillY+26)); line.line(to:NSPoint(x:center+20,y:pillY+26)); line.stroke()
  NSGraphicsContext.restoreGraphicsState()
  let name="bridge-header-v2-\(dark ? "dark" : "light")\(mobile ? "-mobile" : "").png"
  try bitmap.representation(using:.png,properties:[:])!.write(to:root.appendingPathComponent("docs/assets/"+name))
 }
}
