#import <Foundation/Foundation.h>
#import <OCHamcrestIOS/OCHamcrestIOS.h>
#import <OCMock/OCMock.h>
#import <XCTest/XCTest.h>

#import "MSFileUtil.h"
#import "MSStorageTestUtil.h"

@interface MSFileUtilTests : XCTestCase

@end

@implementation MSFileUtilTests

#pragma mark - Houskeeping

- (void)setUp {
  [super setUp];
}

- (void)tearDown {
  [MSFileUtil setFileManager:nil];
  [MSStorageTestUtil resetLogsDirectory];
  [super tearDown];
}

#pragma mark - Tests

- (void)testDefaultFileManagerIsUsedByDefault {

  // If
  NSFileManager *expected = [NSFileManager defaultManager];

  // When
  NSFileManager *actual = [MSFileUtil fileManager];

  // Then
  assertThat(expected, equalTo(actual));
}

- (void)testCustomSetFileManagerWorks {

  // If
  NSFileManager *expected = [NSFileManager new];

  // When
  [MSFileUtil setFileManager:expected];

  // Then
  NSFileManager *actual = [MSFileUtil fileManager];
  assertThat(expected, equalTo(actual));
}

- (void)testStorageSubDirectoriesAreExcludedFromBackupButAppSupportFolderIsNotAffected {

  // Explicitly do not exclude app support folder from backups
  NSError *getResourceError = nil;
  NSNumber *resourceValue = nil;
  NSString *appSupportPath =
      [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject];
  XCTAssertTrue([[NSURL fileURLWithPath:appSupportPath] setResourceValue:@NO
                                                                  forKey:NSURLIsExcludedFromBackupKey
                                                                   error:&getResourceError]);

  // Create first file and verify that subdirectory is excluded from backups
  getResourceError = nil;
  resourceValue = nil;
  NSString *subDirectory = @"testDirectory";
  NSString *fileId = @"fileId";
  NSString *filePath = [MSStorageTestUtil filePathForLogWithId:fileId extension:@"ms" groupId:subDirectory];
  MSFile *file = [[MSFile alloc] initWithURL:[NSURL fileURLWithPath:filePath] fileId:fileId creationDate:[NSDate date]];

  [MSFileUtil writeData:[NSData new] toFile:file];
  NSString *storagePath = [MSStorageTestUtil storageDirForGroupId:subDirectory];
  [[NSURL fileURLWithPath:storagePath] getResourceValue:&resourceValue
                                                 forKey:NSURLIsExcludedFromBackupKey
                                                  error:&getResourceError];
  XCTAssertNil(getResourceError);
  XCTAssertEqual(resourceValue, @YES);

  // Verify that app support folder still isn't excluded
  [[NSURL fileURLWithPath:appSupportPath] getResourceValue:&resourceValue
                                                    forKey:NSURLIsExcludedFromBackupKey
                                                     error:&getResourceError];
  XCTAssertNil(getResourceError);
  XCTAssertEqual(resourceValue, @NO);
}

- (void)testOnlyExistingFileNamesWithExtensionInDirAreReturned {

  // If
  NSString *subDirectory = @"testDirectory";
  NSString *extension = @"ms";
  MSFile *file1 = [MSStorageTestUtil createFileWithId:@"1"
                                                 data:[NSData new]
                                            extension:extension
                                              groupId:subDirectory
                                         creationDate:[NSDate date]];
  MSFile *file2 = [MSStorageTestUtil createFileWithId:@"2"
                                                 data:[NSData new]
                                            extension:extension
                                              groupId:subDirectory
                                         creationDate:[NSDate date]];

  // Create files with searched extension
  NSArray<MSFile *> *expected = @[file1, file2];

  // Create files with different extension
  [MSStorageTestUtil createFileWithId:@"3"
                                 data:[NSData new]
                            extension:@"foo"
                              groupId:subDirectory
                         creationDate:[NSDate date]];

  // When
  NSString *directory = [MSStorageTestUtil storageDirForGroupId:subDirectory];
  NSArray<MSFile *> *actual = [MSFileUtil filesForDirectory:[NSURL fileURLWithPath:directory] withFileExtension:extension];

  // Then
  assertThatInteger(actual.count, equalToInteger(expected.count));
  for (NSUInteger i = 0; i < actual.count; i++) {
    assertThat(actual[i].fileURL, equalTo(expected[i].fileURL));
    assertThat(actual[i].fileId, equalTo(expected[i].fileId));
    assertThat(actual[i].creationDate.description, equalTo(expected[i].creationDate.description));
  }
}

- (void)testCallingFileNamesForDirectoryWithNilPathReturnsNil {

  // If
  id fileManagerMock = OCMClassMock([NSFileManager class]);

  // When
  NSArray *actual = [MSFileUtil filesForDirectory:nil withFileExtension:@"ms"];

  // Then
  assertThat(actual, nilValue());
  OCMReject(
      [fileManagerMock contentsOfDirectoryAtPath:[OCMArg any] error:((NSError __autoreleasing **)[OCMArg anyPointer])]);
}

- (void)testDeletingExistingFileReturnsYes {

  // If
  MSFile *file = [MSStorageTestUtil createFileWithId:@"0"
                                                data:[NSData new]
                                           extension:@"ms"
                                             groupId:@"testDirectory"
                                        creationDate:[NSDate date]];

  // When
  BOOL success = [MSFileUtil deleteFile:file];

  // Then
  assertThatBool(success, isTrue());
}

- (void)testDeletingNonexistingFileReturnsNo {

  // If
  NSString *subDirectory = @"testDirectory";
  NSString *extension = @"ms";
  NSString *fileName = @"foo";
  NSString *filePath = [MSStorageTestUtil filePathForLogWithId:fileName extension:extension groupId:subDirectory];
  MSFile *file = [[MSFile alloc] initWithURL:[NSURL fileURLWithPath:filePath] fileId:fileName creationDate:[NSDate date]];

  // When
  BOOL success = [MSFileUtil deleteFile:file];

  // Then
  assertThatBool(success, isFalse());
}

- (void)testDeletingFileWithEmptyPathReturnsNo {

  // If
  id fileManagerMock = OCMClassMock([NSFileManager class]);
  MSFile *file = [MSStorageTestUtil createFileWithId:@"0"
                                                data:[NSData new]
                                           extension:@"ms"
                                             groupId:@"testDirectory"
                                        creationDate:[NSDate date]];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnonnull"
  file.fileURL = nil;
#pragma clang diagnostic pop

  // When
  BOOL success = [MSFileUtil deleteFile:file];

  // Then
  assertThatBool(success, isFalse());
  OCMReject([fileManagerMock removeItemAtPath:[OCMArg any] error:((NSError __autoreleasing **)[OCMArg anyPointer])]);
}

- (void)testReadingExistingFileReturnsCorrectContent {

  // If
  NSData *expected = [@"0" dataUsingEncoding:NSUTF8StringEncoding];
  MSFile *file = [MSStorageTestUtil createFileWithId:@"0"
                                                data:expected
                                           extension:@"ms"
                                             groupId:@"testDirectory"
                                        creationDate:[NSDate date]];

  // When
  NSData *actual = [MSFileUtil dataForFile:file];

  // Then
  assertThat(actual, equalTo(expected));
}

- (void)testReadingNonexistingFileReturnsNil {

  // If
  NSString *directory = [MSStorageTestUtil logsDir];
  MSFile *file = [MSFile new];
  file.fileURL = [NSURL fileURLWithPath:[directory stringByAppendingPathComponent:@"0.test"]];

  // When
  NSData *actual = [MSFileUtil dataForFile:file];

  // Then
  assertThat(actual, nilValue());
}

- (void)testSuccessfullyWritingDataItemsToFileWorksCorrectly {

  // If
  NSArray *items = @[ @"1", @"2" ];
  NSData *expected = [NSKeyedArchiver archivedDataWithRootObject:items];
  NSString *filePath = [MSStorageTestUtil filePathForLogWithId:@"0" extension:@"ms" groupId:@"directory"];
  MSFile *file = [[MSFile alloc] initWithURL:[NSURL fileURLWithPath:filePath] fileId:@"0" creationDate:[NSDate date]];

  // When
  BOOL success = [MSFileUtil writeData:expected toFile:file];

  // Then
  assertThatBool(success, isTrue());
  assertThat(expected, equalTo([NSData dataWithContentsOfFile:filePath]));
}

- (void)testAppendingDataToNonexistingDirWillCreateDirAndFile {

  // If
  NSString *fileName = @"0";
  NSString *filePath = [MSStorageTestUtil filePathForLogWithId:fileName extension:@"ms" groupId:@"testDirectory"];
  NSData *expected = [@"123456789" dataUsingEncoding:NSUTF8StringEncoding];
  MSFile *file = [[MSFile alloc] initWithURL:[NSURL fileURLWithPath:filePath] fileId:fileName creationDate:[NSDate date]];

  // When
  NSData *actual;
  if ([MSFileUtil writeData:expected toFile:file]) {
    actual = [MSFileUtil dataForFile:file];
  }

  // Then
  assertThat(expected, equalTo(actual));
}

@end
