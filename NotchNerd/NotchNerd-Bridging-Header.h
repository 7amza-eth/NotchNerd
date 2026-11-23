//
//  NotchNerd-Bridging-Header.h
//  NotchNerd
//
//  Private CoreGraphics virtual-display classes (macOS 11+), used by Display/VirtualHiDPI.swift to
//  give external monitors HiDPI ("sharper text") modes. Same declarations as DeskPad and other
//  open-source virtual-display tools. Keep this file to these declarations.
//

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nullable) dispatch_queue_t queue;
@property (copy) NSString *name;
@property unsigned int maxPixelsHigh;
@property unsigned int maxPixelsWide;
@property CGSize sizeInMillimeters;
@property unsigned int serialNum;
@property unsigned int productID;
@property unsigned int vendorID;
@property (copy, nullable) void (^terminationHandler)(id _Nullable, id _Nullable);
@end

@interface CGVirtualDisplayMode : NSObject
@property (readonly) unsigned int width;
@property (readonly) unsigned int height;
@property (readonly) double refreshRate;
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain) NSArray<CGVirtualDisplayMode *> *modes;
@property unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
