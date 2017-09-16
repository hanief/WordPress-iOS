#import "LoginFields.h"
#import "WordPress-Swift.h"

@implementation LoginFields

+ (instancetype)loginFieldsWithUsername:(NSString *)username
                               password:(NSString *)password
                                siteUrl:(NSString *)siteUrl
                        multifactorCode:(NSString *)multifactorCode
                           userIsDotCom:(BOOL)userIsDotCom
               shouldDisplayMultiFactor:(BOOL)shouldDisplayMultifactor
{
    LoginFields *loginFields = [LoginFields new];
    loginFields.username = username;
    loginFields.password = password;
    loginFields.siteUrl = siteUrl;
    loginFields.multifactorCode = multifactorCode;
    loginFields.userIsDotCom = userIsDotCom;
    loginFields.shouldDisplayMultifactor = shouldDisplayMultifactor;
    
    return loginFields;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        _emailAddress = @"";
        _username = @"";
        _password = @"";
        _siteUrl = @"";
        _multifactorCode = @"";
    }
    return self;
}

- (NSDictionary *)helpshiftLoginOptions
{
    return @{
             @"Source": @"Login",
             @"Username": self.username,
             @"SiteURL": self.siteUrl
             };
}

@end
