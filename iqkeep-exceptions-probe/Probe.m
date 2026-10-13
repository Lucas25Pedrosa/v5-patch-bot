#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <fcntl.h>
#import <unistd.h>
#import <limits.h>
#import <stdarg.h>
#import <stdint.h>
#import <stdio.h>
#import <string.h>

static void IQKDELog(const char *format, ...) {
    char message[2048];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);

    @autoreleasepool {
        NSString *line = [NSString stringWithFormat:@"[iQKDE] %s\n", message];
        NSLog(@"%@", [line stringByTrimmingCharactersInSet:NSCharacterSet.newlineCharacterSet]);

        NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/iQKeepDeletedExceptionsProbe.log"];
        int fd = open(path.fileSystemRepresentation, O_CREAT | O_WRONLY | O_APPEND, 0644);
        if (fd >= 0) {
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (data.length > 0) (void)write(fd, data.bytes, data.length);
            close(fd);
        }
    }
}

static void *IQKDEFindLocalSymbol(const struct mach_header_64 *header,
                                  intptr_t slide,
                                  const char *wantedName) {
    if (header == NULL || wantedName == NULL || header->magic != MH_MAGIC_64) return NULL;

    const struct load_command *command = (const struct load_command *)((const uint8_t *)header + sizeof(struct mach_header_64));
    const struct segment_command_64 *linkedit = NULL;
    const struct symtab_command *symtab = NULL;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) linkedit = segment;
        } else if (command->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)command;
        }
        command = (const struct load_command *)((const uint8_t *)command + command->cmdsize);
    }

    if (linkedit == NULL || symtab == NULL) return NULL;

    uintptr_t linkeditBase = (uintptr_t)slide + (uintptr_t)linkedit->vmaddr - (uintptr_t)linkedit->fileoff;
    const struct nlist_64 *symbols = (const struct nlist_64 *)(linkeditBase + symtab->symoff);
    const char *strings = (const char *)(linkeditBase + symtab->stroff);

    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        uint32_t strx = symbols[i].n_un.n_strx;
        if (strx == 0 || symbols[i].n_value == 0) continue;
        const char *name = strings + strx;
        if (strcmp(name, wantedName) == 0) {
            return (void *)((uintptr_t)slide + (uintptr_t)symbols[i].n_value);
        }
    }
    return NULL;
}

static void IQKDEScan(void) {
    uint32_t count = _dyld_image_count();
    IQKDELog("scan images=%u", count);

    for (uint32_t i = 0; i < count; i++) {
        const char *path = _dyld_get_image_name(i);
        if (path == NULL || strstr(path, "iqKeepDeleted.dylib") == NULL) continue;

        const struct mach_header *rawHeader = _dyld_get_image_header(i);
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        if (rawHeader == NULL || rawHeader->magic != MH_MAGIC_64) {
            IQKDELog("iqKeepDeleted encontrado, header inesperado image=%s", path);
            continue;
        }

        const struct mach_header_64 *header = (const struct mach_header_64 *)rawHeader;
        void *deletePtr = IQKDEFindLocalSymbol(header, slide, "_iqt_ext_delete");
        void *globalPtr = IQKDEFindLocalSymbol(header, slide, "_iqt_ext_globalIds");
        IQKDELog("iqKeepDeleted image=%s slide=0x%llx _iqt_ext_delete=%p _iqt_ext_globalIds=%p",
                 path,
                 (unsigned long long)slide,
                 deletePtr,
                 globalPtr);
    }
}

__attribute__((constructor))
static void IQKDEInit(void) {
    @autoreleasepool {
        NSString *bundleId = NSBundle.mainBundle.bundleIdentifier ?: @"";
        NSString *exe = NSBundle.mainBundle.executablePath.lastPathComponent ?: @"";
        if (![bundleId isEqualToString:@"ph.telegra.Telegraph"] && ![exe isEqualToString:@"Telegram"]) return;

        IQKDELog("init v0.1 diagnostic-only bundle=%s exe=%s", bundleId.UTF8String, exe.UTF8String);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            IQKDEScan();
        });
    }
}
