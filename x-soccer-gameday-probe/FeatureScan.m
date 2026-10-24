#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static BOOL XSGContainsAny(NSString *value, NSArray<NSString *> *needles) {
    if (!value.length) return NO;
    for (NSString *needle in needles) {
        if ([value rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

static void XSGEmit(void (*logger)(NSString *), NSString *line) {
    if (logger) logger(line);
    else NSLog(@"[XSoccerGamedayProbe][FEATURE_SCAN] %@", line);
}

void XSGRunFeatureScan(void (*logger)(NSString *)) {
    @autoreleasepool {
        NSArray<NSString *> *classNeedles = @[@"FeatureSwitch", @"FeatureFlag", @"Experiment", @"Gate", @"Decider", @"Sports", @"Soccer"];
        NSArray<NSString *> *selectorNeedles = @[@"bool", @"enabled", @"value", @"feature", @"switch", @"experiment", @"gate", @"decider", @"sports", @"soccer"];

        XSGEmit(logger, @"FEATURE_SCAN_BEGIN");

        int count = objc_getClassList(NULL, 0);
        if (count <= 0) {
            XSGEmit(logger, @"FEATURE_SCAN no runtime classes");
            return;
        }

        __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
        if (!classes) {
            XSGEmit(logger, @"FEATURE_SCAN allocation failed");
            return;
        }

        count = objc_getClassList(classes, count);
        NSUInteger matchedClasses = 0;
        NSUInteger matchedSelectors = 0;

        for (int i = 0; i < count; i++) {
            Class cls = classes[i];
            NSString *className = NSStringFromClass(cls);
            if (!XSGContainsAny(className, classNeedles)) continue;

            matchedClasses++;
            XSGEmit(logger, [NSString stringWithFormat:@"FEATURE_CLASS %@", className]);

            unsigned methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            for (unsigned j = 0; j < methodCount; j++) {
                NSString *selectorName = NSStringFromSelector(method_getName(methods[j]));
                if (!XSGContainsAny(selectorName, selectorNeedles)) continue;
                matchedSelectors++;
                XSGEmit(logger, [NSString stringWithFormat:@"FEATURE_METHOD class=%@ selector=%@", className, selectorName]);
            }
            free(methods);

            Class meta = object_getClass(cls);
            unsigned classMethodCount = 0;
            Method *classMethods = class_copyMethodList(meta, &classMethodCount);
            for (unsigned j = 0; j < classMethodCount; j++) {
                NSString *selectorName = NSStringFromSelector(method_getName(classMethods[j]));
                if (!XSGContainsAny(selectorName, selectorNeedles)) continue;
                matchedSelectors++;
                XSGEmit(logger, [NSString stringWithFormat:@"FEATURE_CLASS_METHOD class=%@ selector=%@", className, selectorName]);
            }
            free(classMethods);
        }

        free(classes);
        XSGEmit(logger, [NSString stringWithFormat:@"FEATURE_SCAN_END classes=%lu selectors=%lu", (unsigned long)matchedClasses, (unsigned long)matchedSelectors]);
    }
}
