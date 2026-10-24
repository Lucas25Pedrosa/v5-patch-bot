#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static BOOL XSGContainsAny(NSString *value, NSArray<NSString *> *needles) {
    if (!value.length) return NO;
    for (NSString *needle in needles) {
        if ([value rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) return YES;
    }
    return NO;
}

__attribute__((constructor))
static void XSGFeatureScanInit(void) {
    @autoreleasepool {
        NSArray<NSString *> *classNeedles = @[@"FeatureSwitch", @"FeatureFlag", @"Experiment", @"Gate", @"Sports", @"Soccer"];
        NSArray<NSString *> *selectorNeedles = @[@"bool", @"enabled", @"value", @"feature", @"switch", @"experiment", @"sports", @"soccer"];

        NSLog(@"[XSoccerGamedayProbe][FEATURE_SCAN] BEGIN");

        int count = objc_getClassList(NULL, 0);
        if (count <= 0) {
            NSLog(@"[XSoccerGamedayProbe][FEATURE_SCAN] no runtime classes");
            return;
        }

        __unsafe_unretained Class *classes = (__unsafe_unretained Class *)calloc((size_t)count, sizeof(Class));
        if (!classes) {
            NSLog(@"[XSoccerGamedayProbe][FEATURE_SCAN] allocation failed");
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
            NSLog(@"[XSoccerGamedayProbe][FEATURE_CLASS] %@", className);

            unsigned methodCount = 0;
            Method *methods = class_copyMethodList(cls, &methodCount);
            for (unsigned j = 0; j < methodCount; j++) {
                SEL selector = method_getName(methods[j]);
                NSString *selectorName = NSStringFromSelector(selector);
                if (!XSGContainsAny(selectorName, selectorNeedles)) continue;
                matchedSelectors++;
                NSLog(@"[XSoccerGamedayProbe][FEATURE_METHOD] class=%@ selector=%@", className, selectorName);
            }
            free(methods);

            Class meta = object_getClass(cls);
            unsigned classMethodCount = 0;
            Method *classMethods = class_copyMethodList(meta, &classMethodCount);
            for (unsigned j = 0; j < classMethodCount; j++) {
                SEL selector = method_getName(classMethods[j]);
                NSString *selectorName = NSStringFromSelector(selector);
                if (!XSGContainsAny(selectorName, selectorNeedles)) continue;
                matchedSelectors++;
                NSLog(@"[XSoccerGamedayProbe][FEATURE_CLASS_METHOD] class=%@ selector=%@", className, selectorName);
            }
            free(classMethods);
        }

        free(classes);
        NSLog(@"[XSoccerGamedayProbe][FEATURE_SCAN] END classes=%lu selectors=%lu", (unsigned long)matchedClasses, (unsigned long)matchedSelectors);
    }
}
