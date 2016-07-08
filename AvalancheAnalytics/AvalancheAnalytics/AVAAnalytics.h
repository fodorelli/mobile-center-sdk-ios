/*
 * Copyright (c) Microsoft Corporation. All rights reserved.
 */

#import <UIKit/UIKit.h>
#import "AVAFeature.h"

@interface AVAAnalytics : AVAFeature

+ (void)sendLog:(NSString*)log;

@end
