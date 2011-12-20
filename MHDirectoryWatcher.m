/*
 *  MHDirectoryWatcher.h
 *  Hacked by Martin Hwasser on 12/19/11.
 */

#import "MHDirectoryWatcher.h"
#include <fcntl.h>
#import <CoreFoundation/CoreFoundation.h>

#define kPollInterval 0.3
#define kPollRetryCount 3

@interface MHDirectoryWatcher (MHDirectoryWatcherPrivate)
- (BOOL)startMonitoringDirectory:(NSString *)dirPath;
- (void)pollDirectoryForChanges:(NSArray *)oldDirectoryMetadata;
@end

@interface MHDirectoryWatcher () {
    dispatch_source_t source;
    int retriesLeft;
}

@property (nonatomic) BOOL isDirectoryChanging;

@end

@implementation MHDirectoryWatcher

@synthesize isDirectoryChanging;
@synthesize watchedPath;

- (void)dealloc
{
    [self setWatchedPath:nil];
    [self stopWatching];
	[super dealloc];
}

+ (MHDirectoryWatcher *)startWatchingFolderWithPath:(NSString *)watchPath
{
	MHDirectoryWatcher *retVal = NULL;
	if (watchPath != NULL) {
		MHDirectoryWatcher *tempManager = [[[MHDirectoryWatcher alloc] init] autorelease];
		if ([tempManager startMonitoringDirectory:watchPath]) {
			// Everything appears to be in order, so return the DirectoryWatcher.
			// Otherwise we'll fall through and return NULL.
            retVal = tempManager;
            [tempManager setWatchedPath:watchPath];
		}
	}
	return retVal;
}

- (void)stopWatching
{
    if (source != NULL) {
        dispatch_source_cancel(source);
        dispatch_release(source);
        source = NULL;
    }
}
- (BOOL)startWatching
{
    return [self startMonitoringDirectory:[self watchedPath]];
}

@end


#pragma mark -

@implementation MHDirectoryWatcher (MHDirectoryWatcherPrivate)

- (NSArray *)directoryMetadata
{
    NSArray *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:[self watchedPath]
                                                                            error:NULL];
    
    NSMutableArray *directoryMetadata = [NSMutableArray array];
    
    for (NSString *fileName in contents) {
        NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
        
        NSString *filePath = [[self watchedPath] stringByAppendingPathComponent:fileName];
        NSDictionary *fileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:filePath 
                                                                                        error:nil];
        NSInteger fileSize = [[fileAttributes objectForKey:NSFileSize] intValue];
        
        // The fileName and fileSize will be our hash key
        NSString *fileHash = [NSString stringWithFormat:@"%@%d", fileName, fileSize];
        // Add it to our metadata list 
        [directoryMetadata addObject:fileHash];

        [pool release];
    }
    return directoryMetadata;
}
- (void)checkChangesAfterDelay:(NSTimeInterval)timeInterval
{
    NSArray *directoryMetadata = [self directoryMetadata];
    
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, timeInterval * NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_current_queue(), ^(void){
        [self pollDirectoryForChanges:directoryMetadata];
    });
}
- (void)pollDirectoryForChanges:(NSArray *)oldDirectoryMetadata
{
    NSArray *newDirectoryMetadata = [self directoryMetadata];
    
    // Check if metadata has changed
    [self setIsDirectoryChanging:![newDirectoryMetadata isEqualToArray:oldDirectoryMetadata]];
    // Reset retries if it's still changing
    retriesLeft = ([self isDirectoryChanging]) ? kPollRetryCount : retriesLeft;
    
    if ([self isDirectoryChanging] || 0 < retriesLeft--) {
        // Either the directory is changing or we should try again
        [self checkChangesAfterDelay:kPollInterval];                    
    } else {
        // Post a notification informating that the directory did change (and seems stable)
        [[NSNotificationCenter defaultCenter] postNotificationName:MHDirectoryDidChangeNotification 
                                                            object:self];
    }
}
- (void)directoryDidChange
{
    if (![self isDirectoryChanging]) {
        isDirectoryChanging = YES;
        retriesLeft = kPollRetryCount;
        [self checkChangesAfterDelay:kPollInterval];
    }
}    

# pragma mark - Monitoring

- (BOOL)startMonitoringDirectory:(NSString *)dirPath
{
    NSAssert(dirPath != nil, @"Path to watch is nil");
    
    // Already monitoring
	if (source != NULL) {
        return NO;
    }
    
	// Open an event-only file descriptor associated with the directory
	int fd = open([dirPath fileSystemRepresentation], O_EVTONLY);
	if (fd < 0) {
        return NO;   
    }
    
    void (^cleanup)() = ^{ 
        close(fd);
    }; 
    // Get a low priority queue
	dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    
	// Monitor the directory for writes
	source = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE,	// dispatch_source_vnode_flags_t
                                    fd, // our file descriptor
                                    DISPATCH_VNODE_WRITE, // mask for writes
                                    queue);
	if (!source) {
        cleanup();
		return NO;
	}
    
	// Call directoryDidChange on event callback
	dispatch_source_set_event_handler(source, ^{
        [self directoryDidChange];
    });
    
    // Dispatch source destructor 
	dispatch_source_set_cancel_handler(source, cleanup);
    
	// Sources are create in suspended state, so resume it
	dispatch_resume(source);
    
    // Everything was OK
    return YES;
}

@end
