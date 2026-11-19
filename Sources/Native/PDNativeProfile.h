#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <mach-o/loader.h>
#import <mach/machine.h>
#import "PDNativePolicy.h"
#import <dlfcn.h>
#if __has_feature(ptrauth_calls)
#import <ptrauth.h>
#endif

// Target profile: reviewed iOS15.4.1 UIKitCore. A different image/code refuses;
// never falls back to the lazy getter or creates a second presentation manager.
static id PDReadCachedPresentationManager(id scene) {
#if defined(__arm64__)
    Method m = class_getInstanceMethod(object_getClass(scene), NSSelectorFromString(@"uiPresentationManager"));
    if (!m || !PDMethodMatches(m,"@",@[])) return nil;
    IMP raw = method_getImplementation(m);
#if __has_feature(ptrauth_calls)
    const uint8_t *code = (const uint8_t *)ptrauth_strip((void *)raw,ptrauth_key_function_pointer);
#else
    const uint8_t *code = (const uint8_t *)(void *)raw;
#endif
    Dl_info info;
    if (!code || !dladdr(code,&info) || !info.dli_fbase) return nil;
    const struct mach_header_64 *header = info.dli_fbase;
    if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64 ||
        header->ncmds > 2048 || header->sizeofcmds > 4194304) return nil;
    const uint8_t expected[16] = {0xe6,0xe8,0x9b,0xb5,0xb5,0x86,0x37,0x25,0xbf,0x8f,0x4c,0x85,0xdc,0xd4,0x43,0xbd};
    const uint8_t *commands = (const uint8_t *)(header+1), *end = commands+header->sizeofcmds;
    const uint8_t *cursor = commands; BOOL identity = NO; uintptr_t textVM = 0;
    uintptr_t methodStart = 0, methodEnd = 0;
    for (uint32_t n=0;n<header->ncmds;n++) {
        if (cursor+sizeof(struct load_command)>end) return nil;
        const struct load_command *lc = (const void *)cursor;
        if (lc->cmdsize<sizeof(*lc) || cursor+lc->cmdsize>end) return nil;
        if (lc->cmd==LC_UUID && lc->cmdsize>=sizeof(struct uuid_command))
            identity = !memcmp(((const struct uuid_command *)lc)->uuid,expected,16);
        if (lc->cmd==LC_SEGMENT_64 && lc->cmdsize>=sizeof(struct segment_command_64)) {
            const struct segment_command_64 *segment = (const void *)lc;
            if (segment->nsects>256 || sizeof(*segment)+(size_t)segment->nsects*sizeof(struct section_64)>lc->cmdsize) return nil;
            if (!strncmp(segment->segname,"__TEXT",16)) textVM = segment->vmaddr;
            const struct section_64 *sections = (const void *)(segment+1);
            for (uint32_t k=0;k<segment->nsects;k++) if (!strncmp(sections[k].segname,"__TEXT",16) && !strncmp(sections[k].sectname,"__text",16)) {
                methodStart = sections[k].addr; methodEnd = sections[k].addr+sections[k].size;
            }
        }
        cursor+=lc->cmdsize;
    }
    if (!identity || !textVM || !methodStart || methodEnd<methodStart) return nil;
    uintptr_t slide = (uintptr_t)header-textVM, address = (uintptr_t)code;
    if (address<methodStart+slide || address>methodEnd+slide || methodEnd+slide-address<228) return nil;
    uint32_t words[4]; uint64_t decodedKey;
    memcpy(words,code+212,sizeof(words));
    if (!PDDecodeAssociationKey(address,words,&decodedKey)) return nil;
    uintptr_t key = (uintptr_t)decodedKey;
    BOOL keyInImage = NO; cursor = commands;
    for (uint32_t n=0;n<header->ncmds;n++) {
        const struct load_command *lc=(const void *)cursor;
        if (lc->cmd==LC_SEGMENT_64) {
            const struct segment_command_64 *s=(const void *)lc;
            if (key>=s->vmaddr+slide && key-s->vmaddr-slide<s->vmsize) keyInImage=YES;
        }
        cursor+=lc->cmdsize;
    }
    return keyInImage ? objc_getAssociatedObject(scene,(const void *)key) : nil;
#else
    (void)scene; return nil;
#endif
}
