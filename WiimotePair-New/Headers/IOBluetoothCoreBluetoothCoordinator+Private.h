@interface IOBluetoothCoreBluetoothCoordinator : NSObject

+ (IOBluetoothCoreBluetoothCoordinator*)sharedInstance;

- (void)pairPeer:(id)peer forType:(NSUInteger)type withKey:(NSNumber*)key;

@end
