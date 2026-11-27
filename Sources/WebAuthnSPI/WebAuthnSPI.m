#import "WebAuthnSPI.h"
#import <objc/runtime.h>

// WebKit's private interfaces, as declared in its _WKWebAuthenticationPanel.h and friends (macOS 26 and later). Every
// class and selector is checked by +missing before use.

@interface _WKPublicKeyCredentialDescriptor : NSObject
- (instancetype)initWithIdentifier:(NSData *)identifier;
@property (nullable, nonatomic, copy) NSArray<NSNumber *> *transports;
@end
@interface _WKAuthenticationExtensionsClientInputs : NSObject
@property (nullable, nonatomic, copy) NSString *appid;
@end
@interface _WKPublicKeyCredentialRequestOptions : NSObject
@property (nullable, nonatomic, copy) NSNumber *timeout;
@property (nullable, nonatomic, copy) NSString *relyingPartyIdentifier;
@property (nullable, nonatomic, copy) NSArray *allowCredentials;
@property (nonatomic) NSInteger userVerification;
@property (nonatomic) NSInteger authenticatorAttachment;
@property (nullable, nonatomic, strong) _WKAuthenticationExtensionsClientInputs *extensions;
@end
@interface _WKPublicKeyCredentialRelyingPartyEntity : NSObject
- (instancetype)initWithName:(NSString *)name;
@property (nullable, nonatomic, copy) NSString *identifier;
@end
@interface _WKPublicKeyCredentialUserEntity : NSObject
- (instancetype)initWithName:(NSString *)name identifier:(NSData *)identifier displayName:(NSString *)displayName;
@end
@interface _WKPublicKeyCredentialParameters : NSObject
- (instancetype)initWithAlgorithm:(NSNumber *)algorithm;
@end
@interface _WKAuthenticatorSelectionCriteria : NSObject
@property (nonatomic) NSInteger authenticatorAttachment;
@property (nonatomic) NSInteger residentKey;
@property (nonatomic) NSInteger userVerification;
@end
@interface _WKPublicKeyCredentialCreationOptions : NSObject
- (instancetype)initWithRelyingParty:(id)rp user:(id)user publicKeyCredentialParamaters:(NSArray *)params;
@property (nullable, nonatomic, copy) NSNumber *timeout;
@property (nullable, nonatomic, strong) _WKAuthenticatorSelectionCriteria *authenticatorSelection;
@property (nullable, nonatomic, copy) NSArray *excludeCredentials;
@property (nonatomic) NSInteger attestation;
@end
@interface _WKAuthenticatorResponse : NSObject
@property (nonatomic, readonly) NSData *rawId;
@property (nullable, nonatomic, copy) NSData *extensionOutputsCBOR;
@end
@interface _WKAuthenticatorAttestationResponse : _WKAuthenticatorResponse
@property (nonatomic, readonly) NSData *attestationObject;
@property (nonatomic, copy) NSArray<NSNumber *> *transports;
@end
@interface _WKAuthenticatorAssertionResponse : _WKAuthenticatorResponse
@property (nonatomic, readonly) NSData *authenticatorData;
@property (nonatomic, readonly) NSData *signature;
@property (nullable, nonatomic, readonly) NSData *userHandle;
@end
@interface _WKWebAuthenticationPanel : NSObject
@property (nullable, nonatomic, weak) id delegate;
- (void)makeCredentialWithClientDataHash:(NSData *)hash options:(id)options completionHandler:(void (^)(id, NSError *))handler;
- (void)getAssertionWithClientDataHash:(NSData *)hash options:(id)options completionHandler:(void (^)(id, NSError *))handler;
- (void)cancel;
@end

static NSError *failure(NSString *message) {
    return [NSError errorWithDomain:@"agweb.security-key" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

@implementation AGWKeyPanel {
    _WKWebAuthenticationPanel *_panel;
    BOOL _pinWasWrong;
}

+ (nullable NSString *)missing {
    NSDictionary<NSString *, NSArray<NSString *> *> *needs = @{
        @"_WKWebAuthenticationPanel": @[@"init", @"setDelegate:", @"cancel", @"makeCredentialWithClientDataHash:options:completionHandler:",
                                        @"getAssertionWithClientDataHash:options:completionHandler:"],
        @"_WKPublicKeyCredentialDescriptor": @[@"initWithIdentifier:", @"setTransports:"],
        @"_WKAuthenticationExtensionsClientInputs": @[@"init", @"setAppid:"],
        @"_WKPublicKeyCredentialRequestOptions": @[@"init", @"setTimeout:", @"setRelyingPartyIdentifier:", @"setAllowCredentials:",
                                                   @"setUserVerification:", @"setAuthenticatorAttachment:", @"setExtensions:"],
        @"_WKPublicKeyCredentialRelyingPartyEntity": @[@"initWithName:", @"setIdentifier:"],
        @"_WKPublicKeyCredentialUserEntity": @[@"initWithName:identifier:displayName:"],
        @"_WKPublicKeyCredentialParameters": @[@"initWithAlgorithm:"],
        @"_WKAuthenticatorSelectionCriteria": @[@"init", @"setAuthenticatorAttachment:", @"setResidentKey:", @"setUserVerification:"],
        @"_WKPublicKeyCredentialCreationOptions": @[@"initWithRelyingParty:user:publicKeyCredentialParamaters:", @"setTimeout:",
                                                    @"setAuthenticatorSelection:", @"setExcludeCredentials:", @"setAttestation:"],
        @"_WKAuthenticatorResponse": @[@"rawId", @"extensionOutputsCBOR"],
        @"_WKAuthenticatorAttestationResponse": @[@"attestationObject", @"transports"],
        @"_WKAuthenticatorAssertionResponse": @[@"authenticatorData", @"signature", @"userHandle"],
    };
    for (NSString *name in needs) {
        Class cls = NSClassFromString(name);
        if (!cls) return [NSString stringWithFormat:@"WebKit has no %@", name];
        for (NSString *selector in needs[name]) {
            if (![cls instancesRespondToSelector:NSSelectorFromString(selector)]) return [NSString stringWithFormat:@"WebKit's %@ has no %@", name, selector];
        }
    }
    return nil;
}

- (void)log:(NSString *)line {
    if (self.onLog) self.onLog(line);
}

- (_WKWebAuthenticationPanel *)freshPanel {
    _panel = [[NSClassFromString(@"_WKWebAuthenticationPanel") alloc] init];
    _panel.delegate = self;
    _pinWasWrong = NO;
    return _panel;
}

static NSNumber *milliseconds(NSTimeInterval seconds) { return @((long long)(seconds * 1000)); }

- (void)makeCredentialWithHash:(NSData *)hash rpID:(NSString *)rpID rpName:(NSString *)rpName userID:(NSData *)userID userName:(NSString *)userName
                   displayName:(NSString *)displayName algorithms:(NSArray<NSNumber *> *)algorithms residentKey:(NSInteger)residentKey
              userVerification:(NSInteger)userVerification attestation:(NSInteger)attestation exclude:(NSArray<NSData *> *)exclude
                       timeout:(NSTimeInterval)timeout
                    completion:(void (^)(NSData *, NSData *, NSArray<NSNumber *> *, NSError *))completion {
    @try {
        _WKPublicKeyCredentialRelyingPartyEntity *rp = [[NSClassFromString(@"_WKPublicKeyCredentialRelyingPartyEntity") alloc] initWithName:rpName.length ? rpName : rpID];
        rp.identifier = rpID;
        id user = [[NSClassFromString(@"_WKPublicKeyCredentialUserEntity") alloc] initWithName:userName identifier:userID displayName:displayName];
        NSMutableArray *params = [NSMutableArray array];
        for (NSNumber *algorithm in algorithms) [params addObject:[[NSClassFromString(@"_WKPublicKeyCredentialParameters") alloc] initWithAlgorithm:algorithm]];
        _WKPublicKeyCredentialCreationOptions *options = [[NSClassFromString(@"_WKPublicKeyCredentialCreationOptions") alloc] initWithRelyingParty:rp user:user publicKeyCredentialParamaters:params];
        options.timeout = milliseconds(timeout);
        _WKAuthenticatorSelectionCriteria *selection = [[NSClassFromString(@"_WKAuthenticatorSelectionCriteria") alloc] init];
        selection.authenticatorAttachment = 2; // cross-platform: never the platform authenticator
        selection.residentKey = residentKey;
        selection.userVerification = userVerification;
        options.authenticatorSelection = selection;
        options.attestation = attestation;
        NSMutableArray *excluded = [NSMutableArray array];
        for (NSData *identifier in exclude) [excluded addObject:[[NSClassFromString(@"_WKPublicKeyCredentialDescriptor") alloc] initWithIdentifier:identifier]];
        options.excludeCredentials = excluded;
        [self log:[NSString stringWithFormat:@"webkit: makeCredential rp %@, %lu algorithms, residentKey %ld, uv %ld, attestation %ld, %lu excluded, timeout %.0fs",
                   rpID, (unsigned long)algorithms.count, (long)residentKey, (long)userVerification, (long)attestation, (unsigned long)exclude.count, timeout]];
        [[self freshPanel] makeCredentialWithClientDataHash:hash options:options completionHandler:^(id response, NSError *error) {
            if (!response) return completion(nil, nil, nil, error ?: failure(@"WebKit gave no response"));
            _WKAuthenticatorAttestationResponse *made = response;
            completion(made.rawId, made.attestationObject, made.transports, nil);
        }];
    } @catch (NSException *exception) {
        completion(nil, nil, nil, failure([NSString stringWithFormat:@"WebKit raised %@: %@", exception.name, exception.reason]));
    }
}

- (void)getAssertionWithHash:(NSData *)hash rpID:(NSString *)rpID allow:(NSArray<NSData *> *)allow userVerification:(NSInteger)userVerification
                       appID:(NSString *)appID timeout:(NSTimeInterval)timeout
                  completion:(void (^)(NSData *, NSData *, NSData *, NSData *, NSData *, NSError *))completion {
    @try {
        _WKPublicKeyCredentialRequestOptions *options = [[NSClassFromString(@"_WKPublicKeyCredentialRequestOptions") alloc] init];
        options.relyingPartyIdentifier = rpID;
        options.timeout = milliseconds(timeout);
        options.userVerification = userVerification;
        options.authenticatorAttachment = 2; // cross-platform
        NSMutableArray *allowed = [NSMutableArray array];
        for (NSData *identifier in allow) {
            _WKPublicKeyCredentialDescriptor *descriptor = [[NSClassFromString(@"_WKPublicKeyCredentialDescriptor") alloc] initWithIdentifier:identifier];
            descriptor.transports = @[@0]; // USB
            [allowed addObject:descriptor];
        }
        options.allowCredentials = allowed;
        if (appID) {
            _WKAuthenticationExtensionsClientInputs *extensions = [[NSClassFromString(@"_WKAuthenticationExtensionsClientInputs") alloc] init];
            extensions.appid = appID;
            options.extensions = extensions;
        }
        [self log:[NSString stringWithFormat:@"webkit: getAssertion rp %@, %lu allowed, uv %ld, appid %@, timeout %.0fs",
                   rpID, (unsigned long)allow.count, (long)userVerification, appID ?: @"none", timeout]];
        [[self freshPanel] getAssertionWithClientDataHash:hash options:options completionHandler:^(id response, NSError *error) {
            if (!response) return completion(nil, nil, nil, nil, nil, error ?: failure(@"WebKit gave no response"));
            _WKAuthenticatorAssertionResponse *signedResponse = response;
            completion(signedResponse.rawId, signedResponse.authenticatorData, signedResponse.signature, signedResponse.userHandle,
                       signedResponse.extensionOutputsCBOR, nil);
        }];
    } @catch (NSException *exception) {
        completion(nil, nil, nil, nil, nil, failure([NSString stringWithFormat:@"WebKit raised %@: %@", exception.name, exception.reason]));
    }
}

- (void)cancel {
    @try { [_panel cancel]; } @catch (NSException *exception) { [self log:[NSString stringWithFormat:@"webkit: cancel raised %@", exception.reason]]; }
}

// MARK: _WKWebAuthenticationPanelDelegate

- (void)panel:(id)panel updateWebAuthenticationPanel:(NSInteger)update {
    [self log:[NSString stringWithFormat:@"webkit: panel update %ld", (long)update]];
    if (update == 4) _pinWasWrong = YES; // _WKWebAuthenticationPanelUpdatePINInvalid
    if (self.onUpdate) self.onUpdate(update);
}

- (void)panel:(id)panel dismissWebAuthenticationPanelWithResult:(NSInteger)result {
    [self log:[NSString stringWithFormat:@"webkit: panel dismissed with result %ld", (long)result]];
}

- (void)panel:(id)panel requestPINWithRemainingRetries:(NSUInteger)retries completionHandler:(void (^)(NSString *))completionHandler {
    [self log:[NSString stringWithFormat:@"webkit: key asks for its PIN, %lu retries left%@", (unsigned long)retries, _pinWasWrong ? @" (last one wrong)" : @""]];
    if (!self.onPIN) return completionHandler(nil);
    self.onPIN(retries == NSUIntegerMax ? NSNotFound : (NSInteger)retries, ^(NSString *pin) { completionHandler(pin); });
}

- (void)panel:(id)panel requestNewPINWithMinLength:(NSUInteger)minLength completionHandler:(void (^)(NSString *))completionHandler {
    // Setting a key's first PIN is for the key's own tools (ykman), not a site's sign-up.
    [self log:[NSString stringWithFormat:@"webkit: key has no PIN and WebKit asks to set one (min %lu); refused", (unsigned long)minLength]];
    completionHandler(nil);
    if (self.onUpdate) self.onUpdate(-1);
}

- (void)panel:(id)panel selectAssertionResponse:(NSArray *)responses source:(NSInteger)source completionHandler:(void (^)(id))completionHandler {
    [self log:[NSString stringWithFormat:@"webkit: key offers %lu accounts (source %ld); taking the first", (unsigned long)responses.count, (long)source]];
    completionHandler(responses.firstObject);
}

- (void)panel:(id)panel decidePolicyForLocalAuthenticatorWithCompletionHandler:(void (^)(NSInteger))completionHandler {
    [self log:@"webkit: asked about the platform authenticator; disallowed"];
    completionHandler(1); // _WKLocalAuthenticatorPolicyDisallow
}

- (void)panel:(id)panel requestLAContextForUserVerificationWithCompletionHandler:(void (^)(id))completionHandler {
    [self log:@"webkit: asked for an LAContext; none"];
    completionHandler(nil);
}

@end
