#pragma once

#import "TerrainTypes.h"
#import "TerrainNoise.h"

#ifdef __OBJC__
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
@interface NSBundle (SceneSprocketsTerrainShaders)
+ (NSBundle *)sceneSprocketsTerrainShadersBundle;
@end
NS_ASSUME_NONNULL_END
#endif
