#pragma once

#import "ToonTypes.h"

#ifdef __OBJC__
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface NSBundle (SceneSprocketsToonShaders)
+ (NSBundle *)sceneSprocketsToonShadersBundle;
@end
NS_ASSUME_NONNULL_END
#endif
