#import <Foundation/Foundation.h>
#import <Security/Authorization.h>
#import <Security/AuthorizationTags.h>
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        if (argc < 2) {
            printf("Usage: %s <command> [args...]\n", argv[0]);
            return 1;
        }
        
        AuthorizationRef authRef = NULL;
        OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &authRef);
        
        if (status != errAuthorizationSuccess) {
            NSLog(@"AuthorizationCreate failed: %d", (int)status);
            return 1;
        }
        
        AuthorizationItem right = {kAuthorizationRightExecute, 0, NULL, 0};
        AuthorizationRights rights = {1, &right};
        AuthorizationFlags flags = kAuthorizationFlagDefaults | kAuthorizationFlagInteractionAllowed | kAuthorizationFlagPreAuthorize | kAuthorizationFlagExtendRights;
        
        status = AuthorizationCopyRights(authRef, &rights, kAuthorizationEmptyEnvironment, flags, NULL);
        
        if (status != errAuthorizationSuccess) {
            NSLog(@"AuthorizationCopyRights failed: %d", (int)status);
            return 1;
        }
        
        const char *tool = argv[1];
        char *args[argc];
        for (int i = 2; i < argc; i++) {
            args[i - 2] = (char *)argv[i];
        }
        args[argc - 2] = NULL;
        
        FILE *pipe = NULL;
        status = AuthorizationExecuteWithPrivileges(authRef, tool, kAuthorizationFlagDefaults, args, &pipe);
        
        if (status != errAuthorizationSuccess) {
            NSLog(@"AuthorizationExecuteWithPrivileges failed: %d", (int)status);
            return 1;
        }
        
        if (pipe) {
            char buffer[1024];
            while (fgets(buffer, sizeof(buffer), pipe) != NULL) {
                printf("%s", buffer);
            }
            fclose(pipe);
        }
        
        AuthorizationFree(authRef, kAuthorizationFlagDestroyRights);
    }
    return 0;
}
