//
//  main.m
//  testesttest
//
//  Created by Ilya on 2/25/15.
//  Copyright (c) 2015 Ilya Konstantinov. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "AppDelegate.h"
#import "gst_ios_init.h"

int main(int argc, char * argv[]) {
    @autoreleasepool {
        gst_ios_init();
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
