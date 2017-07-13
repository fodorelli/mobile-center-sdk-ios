#import "MSChannelDefault.h"
#import "MSChannelDefaultPrivate.h"
#import "MSMobileCenterErrors.h"
#import "MSMobileCenterInternal.h"

@implementation MSChannelDefault

@synthesize configuration = _configuration;

#pragma mark - Initialization

- (instancetype)init {
  if ((self = [super init])) {
    _itemsCount = 0;
    _pendingBatchIds = [NSMutableArray new];
    _pendingBatchQueueFull = NO;
    _availableBatchFromStorage = NO;
    _enabled = YES;

    _delegates = [NSHashTable weakObjectsHashTable];
  }
  return self;
}

- (instancetype)initWithSender:(id<MSSender>)sender
                       storage:(id<MSStorage>)storage
                 configuration:(MSChannelConfiguration *)configuration
             logsDispatchQueue:(dispatch_queue_t)logsDispatchQueue {
  if ((self = [self init])) {
    _sender = sender;
    _storage = storage;
    _configuration = configuration;
    _logsDispatchQueue = logsDispatchQueue;

    // Register as sender delegate.
    [_sender addDelegate:self];

    // Match sender's current status.
    if (_sender.suspended) {
      [self suspend];
    }
  }
  return self;
}

#pragma mark - MSChannelDelegate

- (void)addDelegate:(id<MSChannelDelegate>)delegate {
  dispatch_async(self.logsDispatchQueue, ^{
    [self.delegates addObject:delegate];
  });
}

- (void)removeDelegate:(id<MSChannelDelegate>)delegate {
  dispatch_async(self.logsDispatchQueue, ^{
    [self.delegates removeObject:delegate];
  });
}

#pragma mark - Managing queue

- (void)enqueueItem:(id<MSLog>)item withCompletion:(enqueueCompletionBlock)completion {

  // Return fast in case our item is empty or we are discarding logs right now.
  dispatch_async(self.logsDispatchQueue, ^{
    if (!item || ![item isValid]) {
      MSLogWarning([MSMobileCenter logTag], @"Log is not valid.");

      // Don't forget to execute completion block.
      if (completion) {
        completion(NO);
      }
      return;
    } else if (self.discardLogs) {
      MSLogWarning([MSMobileCenter logTag], @"Channel disabled in log discarding mode, discard this log.");
      NSError *error = [NSError errorWithDomain:kMSMCErrorDomain
                                           code:kMSMCConnectionSuspendedErrorCode
                                       userInfo:@{NSLocalizedDescriptionKey : kMSMCConnectionSuspendedErrorDesc}];
      [self notifyFailureBeforeSendingForItem:item withError:error];

      // Don't forget to execute the completion block.
      if (completion) {
        completion(NO);
      }
      return;
    }

    // Save the log first.
    MSLogDebug([MSMobileCenter logTag], @"Saving log, type: %@.", item.type);
    BOOL success = [self.storage saveLog:item withGroupId:self.configuration.groupId];
    self.itemsCount += 1;

    // Execute the completion block.
    if (completion) {
      completion(success);
    }

    // Flush now if current batch is full or delay to later.
    if (self.itemsCount >= self.configuration.batchSizeLimit) {
      [self flushQueue];
    } else if (self.itemsCount == 1) {

      // Don't delay if channel is suspended but stack logs until current batch max out.
      if (!self.suspended) {
        [self startTimer];
      }
    }
  });
}

- (void)flushQueue {

  // Cancel any timer.
  [self resetTimer];

  // Don't flush while suspended or if pending bach queue is full.
  if (self.suspended || self.pendingBatchQueueFull) {

    // Still close the current batch it will be flushed later.
    if (self.itemsCount >= self.configuration.batchSizeLimit) {
      [self.storage closeBatchWithGroupId:self.configuration.groupId];

      // That batch becomes available.
      self.availableBatchFromStorage = YES;
      self.itemsCount = 0;
    }
    return;
  }

  // Reset item count and load data from the storage.
  self.itemsCount = 0;
  self.availableBatchFromStorage = [self.storage
      loadLogsForGroupId:self.configuration.groupId
          withCompletion:^(BOOL succeeded, NSArray<MSLog> *_Nonnull logArray, NSString *_Nonnull batchId) {

               // Logs may be deleted from storage before this flush.
               if (succeeded) {
                 [self.pendingBatchIds addObject:batchId];
                 if (self.pendingBatchIds.count >= self.configuration.pendingBatchesLimit) {
                   self.pendingBatchQueueFull = YES;
                 }
                 MSLogContainer *container = [[MSLogContainer alloc] initWithBatchId:batchId andLogs:logArray];
                 MSLogDebug([MSMobileCenter logTag], @"Sending log(s), batch Id:%@, payload:\n%@", batchId,
                            [container serializeLogWithPrettyPrinting:YES]);

              // Notify delegates.
              [self enumerateDelegatesForSelector:@selector(channel:willSendLog:)
                                        withBlock:^(id<MSChannelDelegate> delegate) {
                                          for (id<MSLog> aLog in logArray) {
                                            [delegate channel:self willSendLog:aLog];
                                          }
                                        }];

                 // Forward logs to the sender.
                 [self.sender
                             sendAsync:container
                     completionHandler:^(NSString *senderBatchId, NSUInteger statusCode, __attribute__((unused)) NSData *data, NSError *error) {
                       dispatch_async(self.logsDispatchQueue, ^{
                         if ([self.pendingBatchIds containsObject:senderBatchId]) {

                        // Success.
                        if (statusCode == MSHTTPCodesNo200OK) {
                          MSLogDebug([MSMobileCenter logTag], @"Log(s) sent with success, batch Id:%@.", senderBatchId);

                          // Notify delegates.
                          [self enumerateDelegatesForSelector:@selector(channel:didSucceedSendingLog:)
                                                    withBlock:^(id<MSChannelDelegate> delegate) {
                                                      for (id<MSLog> aLog in logArray) {
                                                        [delegate channel:self didSucceedSendingLog:aLog];
                                                      }
                                                    }];

                          // Remove from pending logs and storage.
                          [self.pendingBatchIds removeObject:senderBatchId];
                          [self.storage deleteLogsForId:senderBatchId withGroupId:self.configuration.groupId];

                          // Try to flush again if batch queue is not full anymore.
                          if (self.pendingBatchQueueFull &&
                              self.pendingBatchIds.count < self.configuration.pendingBatchesLimit) {
                            self.pendingBatchQueueFull = NO;
                            if (self.availableBatchFromStorage) {
                              [self flushQueue];
                            }
                          }
                        }

                        // Failure.
                        else {
                          MSLogDebug([MSMobileCenter logTag], @"Log(s) sent with failure, batch Id:%@, status code:%lu",
                                     senderBatchId, (unsigned long)statusCode);

                          // Notify delegates.
                          [self enumerateDelegatesForSelector:@selector(channel:didFailSendingLog:withError:)
                                                    withBlock:^(id<MSChannelDelegate> delegate) {
                                                      for (id<MSLog> aLog in logArray) {
                                                        [delegate channel:self didFailSendingLog:aLog withError:error];
                                                      }
                                                    }];

                          // Remove from pending logs.
                          [self.pendingBatchIds removeObject:senderBatchId];
                          [self.storage deleteLogsForId:senderBatchId withGroupId:self.configuration.groupId];
                        }
                      } else
                        MSLogWarning([MSMobileCenter logTag], @"Batch Id %@ not expected, ignore.", senderBatchId);
                    });
                  }];
            }
          }];

  // Flush again if there is another batch to send.
  if (self.availableBatchFromStorage && !self.pendingBatchQueueFull) {
    [self flushQueue];
  }
}

#pragma mark - Timer

- (void)startTimer {
  [self resetTimer];

  self.timerSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.logsDispatchQueue);

  /**
   * Cast (NSEC_PER_SEC * self.configuration.flushInterval) to (int64_t) silence warning. The compiler otherwise
   * complains that we're using a float param (flushInterval) and implicitly downcast to int64_t.
   */
  dispatch_source_set_timer(self.timerSource, dispatch_walltime(NULL, (int64_t) (NSEC_PER_SEC * self.configuration.flushInterval)),
                            1ull * NSEC_PER_SEC, 1ull * NSEC_PER_SEC);
  __weak typeof(self) weakSelf = self;
  dispatch_source_set_event_handler(self.timerSource, ^{
    typeof(self) strongSelf = weakSelf;

    // Flush the queue as needed.
    if (strongSelf) {
      if (strongSelf.itemsCount > 0) {
        [strongSelf flushQueue];
      }
      [strongSelf resetTimer];
    }
  });
  dispatch_resume(self.timerSource);
}

- (void)resetTimer {
  if (self.timerSource) {
    dispatch_source_cancel(self.timerSource);
  }
}

#pragma mark - Life cycle

- (void)setEnabled:(BOOL)isEnabled andDeleteDataOnDisabled:(BOOL)deleteData {
  dispatch_async(self.logsDispatchQueue, ^{
    if (self.enabled != isEnabled) {
      self.enabled = isEnabled;
      if (isEnabled) {
        if (!self.sender.suspended){
          [self resume];
        }
      } else {
        [self suspend];
      }
    }

    // Even if it's already disabled we might also want to delete logs this time.
    if (!isEnabled && deleteData) {
      MSLogDebug([MSMobileCenter logTag], @"Delete all logs for goup Id %@", self.configuration.groupId);
      NSError *error = [NSError errorWithDomain:kMSMCErrorDomain
                                           code:kMSMCConnectionSuspendedErrorCode
                                       userInfo:@{NSLocalizedDescriptionKey : kMSMCConnectionSuspendedErrorDesc}];
      [self deleteAllLogsWithErrorSync:error];

      // Reset states.
      self.itemsCount = 0;
      self.availableBatchFromStorage = NO;
      self.pendingBatchQueueFull = NO;

      // Prevent further logs from being persisted.
      self.discardLogs = YES;
    }
  });
}

- (void)suspend {
  if (!self.suspended) {
    MSLogDebug([MSMobileCenter logTag], @"Suspend channel for group Id %@.", self.configuration.groupId);
    self.suspended = YES;
    [self resetTimer];
  }
}

- (void)resume {
  if (self.suspended && self.enabled) {
    MSLogDebug([MSMobileCenter logTag], @"Resume channel for group Id %@.", self.configuration.groupId);
    self.suspended = NO;
    self.discardLogs = NO;
    [self flushQueue];
  }
}

#pragma mark - Storage

- (void)deleteAllLogsWithError:(NSError *)error {
  dispatch_async(self.logsDispatchQueue, ^{
    [self deleteAllLogsWithErrorSync:error];
  });
}

- (void)deleteAllLogsWithErrorSync:(NSError *)error {
  NSArray<id<MSLog>> *deletedLogs;

  // Delete pending batches first.
  for (NSString *batchId in self.pendingBatchIds) {
    [self.storage deleteLogsForId:batchId withGroupId:self.configuration.groupId];
  }

  // Delete remaining logs.
  deletedLogs = [self.storage deleteLogsForGroupId:self.configuration.groupId];

  // Notify failure of remaining logs.
  for (id<MSLog> log in deletedLogs) {
    [self notifyFailureBeforeSendingForItem:log withError:error];
  }
}

#pragma mark - MSSenderDelegate

- (void)senderDidSuspend:(id<MSSender>)sender {
  (void)sender;
  dispatch_async(self.logsDispatchQueue, ^{
    [self suspend];
  });
}

- (void)senderDidResume:(id<MSSender>)sender {
  (void)sender;
  dispatch_async(self.logsDispatchQueue, ^{
    [self resume];
  });
}

- (void)senderDidReceiveFatalError:(id<MSSender>)sender {
  (void)sender;
  
  // Disable and delete data on fatal errors.
  [self setEnabled:NO andDeleteDataOnDisabled:YES];
}

#pragma mark - Helper

- (void)enumerateDelegatesForSelector:(SEL)selector withBlock:(void (^)(id<MSChannelDelegate> delegate))block {
  for (id<MSChannelDelegate> delegate in self.delegates) {
    if (delegate && [delegate respondsToSelector:selector]) {
      block(delegate);
    }
  }
}

- (void)notifyFailureBeforeSendingForItem:(id<MSLog>)item withError:(NSError *)error {
  for (id<MSChannelDelegate> delegate in self.delegates) {

    // Call willSendLog before didFailSendingLog
    if (delegate && [delegate respondsToSelector:@selector(channel:willSendLog:)])
      [delegate channel:self willSendLog:item];

    // Call didFailSendingLog
    if (delegate && [delegate respondsToSelector:@selector(channel:didFailSendingLog:withError:)])
      [delegate channel:self didFailSendingLog:item withError:error];
  }
}

@end
