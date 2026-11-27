#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// WebKit's own WebAuthn client for security keys (`_WKWebAuthenticationPanel`, private), driven without its UI:
/// agweb builds the client data, checks the origin and shows the PIN and touch prompts itself. Main thread only.
@interface AGWKeyPanel : NSObject

/// Whether WebKit has every class and selector used here; nil when it does, else what's missing.
+ (nullable NSString *)missing;

/// The key wants its PIN: `retries` left (NSNotFound when unknown); reply nil to cancel.
@property (nonatomic, copy, nullable) void (^onPIN)(NSInteger retries, void (^reply)(NSString *_Nullable pin));
/// WebKit's panel updates (`_WKWebAuthenticationPanelUpdate`), raw; -1 when WebKit asked to set the key's first PIN.
@property (nonatomic, copy, nullable) void (^onUpdate)(NSInteger update);
/// Debug lines for the security key log.
@property (nonatomic, copy, nullable) void (^onLog)(NSString *line);

/// `residentKey`: 1 required, 2 preferred, 3 discouraged. `userVerification`: 0 required, 1 preferred, 2 discouraged.
/// `attestation`: 0 none, 1 indirect, 2 direct, 3 enterprise.
- (void)makeCredentialWithHash:(NSData *)hash
                          rpID:(NSString *)rpID
                        rpName:(NSString *)rpName
                        userID:(NSData *)userID
                      userName:(NSString *)userName
                   displayName:(NSString *)displayName
                    algorithms:(NSArray<NSNumber *> *)algorithms
                   residentKey:(NSInteger)residentKey
              userVerification:(NSInteger)userVerification
                   attestation:(NSInteger)attestation
                       exclude:(NSArray<NSData *> *)exclude
                       timeout:(NSTimeInterval)timeout
                    completion:(void (^)(NSData *_Nullable rawId, NSData *_Nullable attestationObject,
                                         NSArray<NSNumber *> *_Nullable transports, NSError *_Nullable error))completion
    NS_SWIFT_NAME(makeCredential(hash:rpID:rpName:userID:userName:displayName:algorithms:residentKey:userVerification:attestation:exclude:timeout:completion:));

- (void)getAssertionWithHash:(NSData *)hash
                        rpID:(NSString *)rpID
                       allow:(NSArray<NSData *> *)allow
            userVerification:(NSInteger)userVerification
                       appID:(nullable NSString *)appID
                     timeout:(NSTimeInterval)timeout
                  completion:(void (^)(NSData *_Nullable rawId, NSData *_Nullable authenticatorData, NSData *_Nullable signature,
                                       NSData *_Nullable userHandle, NSData *_Nullable extensionsCBOR, NSError *_Nullable error))completion
    NS_SWIFT_NAME(getAssertion(hash:rpID:allow:userVerification:appID:timeout:completion:));

- (void)cancel;

@end

NS_ASSUME_NONNULL_END
