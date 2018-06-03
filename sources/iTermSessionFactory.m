//
//  iTermSessionFactory.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 6/3/18.
//

#import "iTermSessionFactory.h"

#import "DebugLogging.h"
#import "iTermAdvancedSettingsModel.h"
#import "iTermProfilePreferences.h"
#import "iTermParameterPanelWindowController.h"
#import "PTYSession.h"
#import "PseudoTerminal.h"

NS_ASSUME_NONNULL_BEGIN

@implementation iTermSessionFactory {
    iTermParameterPanelWindowController *_parameterPanelWindowController;
}

#pragma mark - API

// Allocate a new session and assign it a bookmark.
- (PTYSession *)newSessionWithProfile:(Profile *)profile {
    assert(profile);
    PTYSession *aSession;

    // Initialize a new session
    aSession = [[PTYSession alloc] initSynthetic:NO];

    [[aSession screen] setUnlimitedScrollback:[profile[KEY_UNLIMITED_SCROLLBACK] boolValue]];
    [[aSession screen] setMaxScrollbackLines:[profile[KEY_SCROLLBACK_LINES] intValue]];

    // set our preferences
    [aSession setProfile:profile];
    return aSession;
}


- (PTYSession *)createSessionWithProfile:(NSDictionary *)profile
                                 withURL:(nullable NSString *)urlString
                           forObjectType:(iTermObjectType)objectType
                        serverConnection:(nullable iTermFileDescriptorServerConnection *)serverConnection
                               canPrompt:(BOOL)canPrompt
                        windowController:(PseudoTerminal *)windowController {
    DLog(@"-createSessionWithProfile:withURL:forObjectType:");
    PTYSession *aSession = [self newSessionWithProfile:profile];
    if (objectType == iTermTabObject) {
        [windowController addSessionInNewTab:aSession];
    }

    // We process the cmd to insert URL parts
    const BOOL ok = [self attachOrLaunchCommandInSession:aSession
                                               canPrompt:canPrompt
                                              objectType:objectType
                                        serverConnection:serverConnection
                                               urlString:urlString
                                            allowURLSubs:YES
                                                  oldCWD:nil
                                        windowController:windowController];
    if (!ok) {
        return nil;
    }

    return aSession;
}

#pragma mark - Private

// Returns nil if the user pressed cancel, otherwise returns a dictionary that's a supeset of |substitutions|.
- (NSDictionary *)substitutionsForCommand:(NSString *)command
                              sessionName:(NSString *)name
                        baseSubstitutions:(NSDictionary *)substitutions
                                canPrompt:(BOOL)canPrompt
                                   window:(NSWindow *)window {
    NSSet *cmdVars = [command doubleDollarVariables];
    NSSet *nameVars = [name doubleDollarVariables];
    NSMutableSet *allVars = [cmdVars mutableCopy];
    [allVars unionSet:nameVars];
    NSMutableDictionary *allSubstitutions = [substitutions mutableCopy];
    for (NSString *var in allVars) {
        if (!substitutions[var]) {
            NSString *value = [self promptForParameter:var promptingDisabled:!canPrompt inWindow:window];
            if (!value) {
                return nil;
            }
            allSubstitutions[var] = value;
        }
    }
    return allSubstitutions;
}

- (BOOL)attachOrLaunchCommandInSession:(PTYSession *)aSession
                             canPrompt:(BOOL)canPrompt
                            objectType:(iTermObjectType)objectType
                      serverConnection:(iTermFileDescriptorServerConnection * _Nullable)serverConnection
                             urlString:(nullable NSString *)urlString
                          allowURLSubs:(BOOL)allowURLSubs
                                oldCWD:(nullable NSString *)oldCWD
                      windowController:(PseudoTerminal * _Nonnull)windowController {
    Profile *profile = [aSession profile];
    NSString *cmd = [ITAddressBookMgr bookmarkCommand:profile
                                        forObjectType:objectType];
    NSString *name = profile[KEY_NAME];

    // If the command or name have any $$VARS$$ not accounted for above, prompt the user for
    // substitutions.
    NSDictionary *substitutions = [self substitutionsForCommand:cmd
                                                    sessionName:name
                                              baseSubstitutions:allowURLSubs ? [self substitutionsForURL:urlString] : @{}
                                                      canPrompt:canPrompt
                                                         window:windowController.window];
    if (!substitutions) {
        return NO;
    }
    cmd = [cmd stringByReplacingOccurrencesOfString:@"$$$$" withString:@"$$"];

    name = [name stringByPerformingSubstitutions:substitutions];
    NSString *pwd = [ITAddressBookMgr bookmarkWorkingDirectory:profile forObjectType:objectType];
    if ([pwd length] == 0) {
        if (oldCWD) {
            pwd = oldCWD;
        } else {
            pwd = NSHomeDirectory();
        }
    }
    NSDictionary *env = @{ @"PWD": pwd };
    BOOL isUTF8 = ([iTermProfilePreferences unsignedIntegerForKey:KEY_CHARACTER_ENCODING inProfile:profile] == NSUTF8StringEncoding);

    [windowController setName:name forSession:aSession];

    // Start the command
    if (serverConnection) {
        assert([iTermAdvancedSettingsModel runJobsInServers]);
        [aSession attachToServer:*serverConnection];
    } else {
        [self startProgram:cmd
               environment:env
                    isUTF8:isUTF8
                 inSession:aSession
             substitutions:substitutions
          windowController:windowController];
    }
    return YES;
}

- (NSDictionary *)substitutionsForURL:(NSString *)urlString {
    NSURL *url = [NSURL URLWithString:urlString];
    return @{ @"$$URL$$": urlString ?: @"",
              @"$$HOST$$": [url host] ?: @"",
              @"$$USER$$": [url user] ?: @"",
              @"$$PASSWORD$$": [url password] ?: @"",
              @"$$PORT$$": [url port] ? [[url port] stringValue] : @"",
              @"$$PATH$$": [url path] ?: @"",
              @"$$RES$$": [url resourceSpecifier] ?: @"" };
}

// Execute the given program and set the window title if it is uninitialized.
- (void)startProgram:(NSString *)command
         environment:(NSDictionary *)prog_env
              isUTF8:(BOOL)isUTF8
           inSession:(PTYSession*)theSession
        substitutions:(NSDictionary *)substitutions
    windowController:(PseudoTerminal *)term {
    [theSession startProgram:command
                 environment:prog_env
                      isUTF8:isUTF8
               substitutions:substitutions];

    if ([[[term window] title] isEqualToString:@"Window"]) {
        [term setWindowTitle];
    }
}

- (NSString *)promptForParameter:(NSString *)name promptingDisabled:(BOOL)promptingDisabled inWindow:(nonnull NSWindow *)window {
    if (promptingDisabled) {
        return @"";
    }
    // Make the name pretty.
    name = [name stringByReplacingOccurrencesOfString:@"$$" withString:@""];
    name = [name stringByReplacingOccurrencesOfString:@"_" withString:@" "];
    name = [name lowercaseString];
    if (name.length) {
        NSString *firstLetter = [name substringWithRange:NSMakeRange(0, 1)];
        NSString *lastLetters = [name substringFromIndex:1];
        name = [[firstLetter uppercaseString] stringByAppendingString:lastLetters];
    }
    _parameterPanelWindowController = [[iTermParameterPanelWindowController alloc] initWithWindowNibName:@"iTermParameterPanelWindowController"];
    [_parameterPanelWindowController.parameterName setStringValue:[NSString stringWithFormat:@"“%@”:", name]];
    [_parameterPanelWindowController.parameterValue setStringValue:@""];

    [window beginSheet:_parameterPanelWindowController.window completionHandler:nil];

    [NSApp runModalForWindow:_parameterPanelWindowController.window];

    [window endSheet:_parameterPanelWindowController.window];

    [_parameterPanelWindowController.window orderOut:self];

    if (_parameterPanelWindowController.canceled) {
        return nil;
    } else {
        return [_parameterPanelWindowController.parameterValue.stringValue copy];
    }
}

@end

NS_ASSUME_NONNULL_END