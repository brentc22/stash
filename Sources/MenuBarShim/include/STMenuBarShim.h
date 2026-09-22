#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Dunne laag om het private MenuBarClientCore-framework.
/// Alles wat met dlopen en NSClassFromString te maken heeft zit hier en nergens anders.
@interface STMenuBarShim : NSObject

/// NO wanneer het framework of een van de twee klassen ontbreekt.
/// Roep dit één keer bij het starten aan en sla het resultaat op.
+ (BOOL)isAvailable;

@end

NS_ASSUME_NONNULL_END
