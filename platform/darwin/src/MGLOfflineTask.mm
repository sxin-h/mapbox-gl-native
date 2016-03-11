#import "MGLOfflineTask_Private.h"

#import "MGLOfflineStorage_Private.h"
#import "MGLOfflineRegion_Private.h"
#import "MGLTilePyramidOfflineRegion.h"

#include <mbgl/storage/default_file_source.hpp>
#include <mbgl/util/string.hpp>

/**
 Assert that the current offline task is valid.
 
 This macro should be used at the beginning of any public-facing instance method
 of `MGLOfflineTask`. For private methods, an assertion is more appropriate.
 */
#define MGLAssertOfflineTaskIsValid() \
    do { \
        if (_state == MGLOfflineTaskStateInvalid) { \
            [NSException raise:@"Invalid offline task" \
                        format: \
             @"-[MGLOfflineStorage removeTask:withCompletionHandler:] has been called " \
             @"on this instance of MGLOfflineTask, rendering it invalid. It is an " \
             @"error to send any message to this task."]; \
        } \
    } while (NO);

class MBGLOfflineRegionObserver : public mbgl::OfflineRegionObserver {
public:
    MBGLOfflineRegionObserver(MGLOfflineTask *offlineTask_) : offlineTask(offlineTask_) {}
    
    void statusChanged(mbgl::OfflineRegionStatus status) override;
    void responseError(mbgl::Response::Error error) override;
    void mapboxTileCountLimitExceeded(uint64_t limit) override;
    
private:
    __weak MGLOfflineTask *offlineTask = nullptr;
};

@interface MGLOfflineTask ()

@property (nonatomic, nullable, readwrite) mbgl::OfflineRegion *mbglOfflineRegion;
@property (nonatomic, readwrite) MGLOfflineTaskState state;
@property (nonatomic, readwrite) MGLOfflineTaskProgress progress;

@end

@implementation MGLOfflineTask

- (instancetype)init {
    [NSException raise:@"Method unavailable"
                format:
     @"-[MGLOfflineTask init] is unavailable. "
     @"Use +[MGLOfflineStorage addTaskForRegion:withContext:completionHandler:] instead."];
    return nil;
}

- (instancetype)initWithMBGLRegion:(mbgl::OfflineRegion *)region {
    if (self = [super init]) {
        _mbglOfflineRegion = region;
        _state = MGLOfflineTaskStateUnknown;
        
        mbgl::DefaultFileSource *mbglFileSource = [[MGLOfflineStorage sharedOfflineStorage] mbglFileSource];
        mbglFileSource->setOfflineRegionObserver(*_mbglOfflineRegion, std::make_unique<MBGLOfflineRegionObserver>(self));
    }
    return self;
}

- (void)dealloc {
    if (_mbglOfflineRegion && _state != MGLOfflineTaskStateInvalid) {
        mbgl::DefaultFileSource *mbglFileSource = [[MGLOfflineStorage sharedOfflineStorage] mbglFileSource];
        mbglFileSource->setOfflineRegionObserver(*_mbglOfflineRegion, nullptr);
    }
}

- (id <MGLOfflineRegion>)region {
    MGLAssertOfflineTaskIsValid();
    
    const mbgl::OfflineRegionDefinition &regionDefinition = _mbglOfflineRegion->getDefinition();
    NSAssert([MGLTilePyramidOfflineRegion conformsToProtocol:@protocol(MGLOfflineRegion_Private)], @"MGLTilePyramidOfflineRegion should conform to MGLOfflineRegion_Private.");
    return [(id <MGLOfflineRegion_Private>)[MGLTilePyramidOfflineRegion alloc] initWithOfflineRegionDefinition:regionDefinition];
}

- (NSData *)context {
    MGLAssertOfflineTaskIsValid();
    
    const mbgl::OfflineRegionMetadata &metadata = _mbglOfflineRegion->getMetadata();
    return [NSData dataWithBytes:&metadata[0] length:metadata.size()];
}

- (void)resume {
    MGLAssertOfflineTaskIsValid();
    
    mbgl::DefaultFileSource *mbglFileSource = [[MGLOfflineStorage sharedOfflineStorage] mbglFileSource];
    mbglFileSource->setOfflineRegionDownloadState(*_mbglOfflineRegion, mbgl::OfflineRegionDownloadState::Active);
}

- (void)suspend {
    MGLAssertOfflineTaskIsValid();
    
    mbgl::DefaultFileSource *mbglFileSource = [[MGLOfflineStorage sharedOfflineStorage] mbglFileSource];
    mbglFileSource->setOfflineRegionDownloadState(*_mbglOfflineRegion, mbgl::OfflineRegionDownloadState::Inactive);
}

- (void)invalidate {
    NSAssert(_state != MGLOfflineTaskStateInvalid, @"Cannot invalidate an already invalid offline task.");
    
    self.state = MGLOfflineTaskStateInvalid;
    self.mbglOfflineRegion = nil;
}

- (void)setState:(MGLOfflineTaskState)state {
    if (!self.mbglOfflineRegion) {
        // A progress update has arrived after the call to
        // -[MGLOfflineStorage removeTask:withCompletionHandler:] but before the
        // removal is complete and the completion handler is called.
        NSAssert(_state == MGLOfflineTaskStateInvalid, @"A valid MGLOfflineTask has no mbgl::OfflineRegion.");
        return;
    }
    
    NSAssert(_state != MGLOfflineTaskStateInvalid, @"Cannot change the state of an invalid offline task.");
    
    _state = state;
}

- (void)requestProgress {
    MGLAssertOfflineTaskIsValid();
    
    mbgl::DefaultFileSource *mbglFileSource = [[MGLOfflineStorage sharedOfflineStorage] mbglFileSource];
    
    __weak MGLOfflineTask *weakSelf = self;
    mbglFileSource->getOfflineRegionStatus(*_mbglOfflineRegion, [&, weakSelf](__unused std::exception_ptr exception, mbgl::optional<mbgl::OfflineRegionStatus> status) {
        if (status) {
            mbgl::OfflineRegionStatus checkedStatus = *status;
            dispatch_async(dispatch_get_main_queue(), ^{
                MGLOfflineTask *strongSelf = weakSelf;
                [strongSelf offlineRegionStatusDidChange:checkedStatus];
            });
        }
    });
}

- (void)offlineRegionStatusDidChange:(mbgl::OfflineRegionStatus)status {
    NSAssert(_state != MGLOfflineTaskStateInvalid, @"Cannot change update progress of an invalid offline task.");
    
    switch (status.downloadState) {
        case mbgl::OfflineRegionDownloadState::Inactive:
            self.state = status.complete() ? MGLOfflineTaskStateComplete : MGLOfflineTaskStateInactive;
            break;
            
        case mbgl::OfflineRegionDownloadState::Active:
            self.state = MGLOfflineTaskStateActive;
            break;
    }
    
    MGLOfflineTaskProgress progress;
    progress.countOfResourcesCompleted = status.completedResourceCount;
    progress.countOfBytesCompleted = status.completedResourceSize;
    progress.countOfResourcesExpected = status.requiredResourceCount;
    progress.maximumResourcesExpected = status.requiredResourceCountIsPrecise ? status.requiredResourceCount : UINT64_MAX;
    self.progress = progress;
    
    if ([self.delegate respondsToSelector:@selector(offlineTask:progressDidChange:)]) {
        [self.delegate offlineTask:self progressDidChange:progress];
    }
}

NSError *MGLErrorFromResponseError(mbgl::Response::Error error) {
    NSInteger errorCode = MGLErrorCodeUnknown;
    switch (error.reason) {
        case mbgl::Response::Error::Reason::NotFound:
            errorCode = MGLErrorCodeNotFound;
            break;
            
        case mbgl::Response::Error::Reason::Server:
            errorCode = MGLErrorCodeBadServerResponse;
            break;
            
        case mbgl::Response::Error::Reason::Connection:
            errorCode = MGLErrorCodeConnectionFailed;
            break;
            
        default:
            break;
    }
    return [NSError errorWithDomain:MGLErrorDomain code:errorCode userInfo:@{
        NSLocalizedFailureReasonErrorKey: @(error.message.c_str())
    }];
}

void MBGLOfflineRegionObserver::statusChanged(mbgl::OfflineRegionStatus status) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSCAssert(offlineTask, @"MBGLOfflineRegionObserver is dangling without an associated MGLOfflineTask.");
        
        [offlineTask offlineRegionStatusDidChange:status];
    });
}

void MBGLOfflineRegionObserver::responseError(mbgl::Response::Error error) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSCAssert(offlineTask, @"MBGLOfflineRegionObserver is dangling without an associated MGLOfflineTask.");
        
        if ([offlineTask.delegate respondsToSelector:@selector(offlineTask:didReceiveError:)]) {
            [offlineTask.delegate offlineTask:offlineTask didReceiveError:MGLErrorFromResponseError(error)];
        }
    });
}

void MBGLOfflineRegionObserver::mapboxTileCountLimitExceeded(uint64_t limit) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSCAssert(offlineTask, @"MBGLOfflineRegionObserver is dangling without an associated MGLOfflineTask.");
        
        if ([offlineTask.delegate respondsToSelector:@selector(offlineTask:didReceiveMaximumAllowedMapboxTiles:)]) {
            [offlineTask.delegate offlineTask:offlineTask didReceiveMaximumAllowedMapboxTiles:limit];
        }
    });
}

@end
