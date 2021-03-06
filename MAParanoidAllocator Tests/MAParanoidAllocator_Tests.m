//
//  MAParanoidAllocator_Tests.m
//  MAParanoidAllocator Tests
//
//  Created by Michael Ash on 4/15/14.
//  Copyright (c) 2014 mikeash. All rights reserved.
//

#import <XCTest/XCTest.h>

#import "MAParanoidAllocator.h"

#import <mach/mach_vm.h>


@interface MAParanoidAllocator_Tests : XCTestCase

@end

@implementation MAParanoidAllocator_Tests

- (void)testSizes {
    MAParanoidAllocator *allocator = [[MAParanoidAllocator alloc] init];
    XCTAssertEqual([allocator size], (size_t)0, @"Unexpected size for freshly allocated allocator");
    [allocator setSize: 42];
    XCTAssertEqual([allocator size], (size_t)42, @"Unexpected size after resizing allocator");
    [allocator setSize: 99999];
    XCTAssertEqual([allocator size], (size_t)99999, @"Unexpected size after resizing allocator");
}

- (void)testAccess {
    MAParanoidAllocator *allocator = [[MAParanoidAllocator alloc] initWithSize: 1];
    [allocator read: ^(const void *ptr) {
        XCTAssertEqual(*(const char *)ptr, (char)0, @"Newly allocated memory should be empty");
    }];
    [allocator write: ^(void *ptr) {
        *(char *)ptr = 1;
    }];
    [allocator read: ^(const void *ptr) {
        XCTAssertEqual(*(const char *)ptr, (char)1, @"Memory write didn't show up");
    }];
}

static int Read(const void *ptr) {
    unsigned char data;
    mach_msg_type_number_t count;
    kern_return_t ret;
    
    ret = mach_vm_read(mach_task_self(), (mach_vm_address_t)ptr, 1, (vm_offset_t *)&data, &count);
    
    if(ret != KERN_SUCCESS) {
        return -1;
    }
    
    return data;
}

static BOOL Write(void *ptr, char value) {
    kern_return_t ret = mach_vm_write(mach_task_self(), (mach_vm_address_t)ptr, (vm_offset_t)&value, 1);
    return ret == KERN_SUCCESS;
}

- (void)testWriteProtection {
    MAParanoidAllocator *allocator = [[MAParanoidAllocator alloc] initWithSize: 1];
    [allocator read: ^(const void *ptr) {
        XCTAssertEqual(Read(ptr), 0, @"Didn't get the expected value from a fresh allocator");
        XCTAssertFalse(Write((void *)ptr, 1), @"Shouldn't be able to write to read-only pointer");
    }];
}

- (void)testReadProtection {
    MAParanoidAllocator *allocator = [[MAParanoidAllocator alloc] initWithSize: 1];
    __block const void *ptr;
    [allocator read: ^(const void *param) {
        XCTAssertEqual(Read(param), 0, @"Didn't get the expected value from a fresh allocator");
        ptr = param;
    }];
    XCTAssertEqual(Read(ptr), -1, @"Shouldn't be able to read from the pointer outside of the block");
}

- (void)testLeadingGuardPage {
    MAParanoidAllocator *allocator = [[MAParanoidAllocator alloc] initWithSize: 1];
    [allocator read: ^(const void *ptr) {
        XCTAssertEqual(Read(ptr), 0, @"Didn't get the expected value from a fresh allocator");
        XCTAssertEqual(Read((const char *)ptr - 1), -1, @"Shouldn't be able to read the byte before an allocation");
    }];
    [allocator write: ^(void *ptr) {
        XCTAssertTrue(Write(ptr, 1), @"Couldn't write to the first byte of the allocator");
        XCTAssertFalse(Write((char *)ptr - 1, 1), @"Shouldn't be able to write to the byte before an allocation");
    }];
}

- (void)testTrailingGuardPage {
    long pageSize = sysconf(_SC_PAGESIZE);
    MAParanoidAllocator *allocator = [[MAParanoidAllocator alloc] initWithSize: pageSize];
    [allocator read: ^(const void *ptr) {
        XCTAssertEqual(Read((const char *)ptr + pageSize - 1), 0, @"Didn't get the expected value from the end of a page in a fresh allocator");
        XCTAssertEqual(Read((const char *)ptr + pageSize), -1, @"Shouldn't be able to read from the page beyond an allocation");
    }];
    [allocator write: ^(void *ptr) {
        XCTAssertTrue(Write((char *)ptr + pageSize - 1, 1), @"Couldn't write to the end of the allocated page");
        XCTAssertFalse(Write((char *)ptr + pageSize, 1), @"Shouldn't be able to write to the page beyond an allocation");
    }];
}

- (void)testResizing {
    long pageSize = sysconf(_SC_PAGESIZE);
    unsigned short randBuf[3] = { 0, 0, 0 };
    MAParanoidAllocator *allocator = [[MAParanoidAllocator alloc] init];
    for(int i = 0; i < 1000; i++) {
        size_t newSize = (nrand48(randBuf) % 1000000) + 1;
        [allocator setSize: newSize];
        [allocator read: ^(const void *ptr) {
            XCTAssertEqual(Read(ptr), 0, @"Didn't get the expected value at the start of the allocation");
            XCTAssertEqual(Read((const char *)ptr + newSize - 1), 0, @"Didn't get the expected value at the end of the allocation");
            XCTAssertEqual(Read((const char *)ptr - 1), -1, @"Shouldn't be able to read before the allocation");
            XCTAssertEqual(Read((const char *)ptr + newSize - 1 + pageSize), -1, @"Shouldn't be able to read after the allocation");
        }];
        [allocator write: ^(void *ptr) {
            XCTAssertTrue(Write(ptr, 0), @"Couldn't write to the start of the allocation");
            XCTAssertTrue(Write((char *)ptr + newSize - 1, 0), @"Couldn't write to the end of the allocation");
            XCTAssertFalse(Write((char *)ptr - 1, 0), @"Shouldn't be able to write before the allocation");
            XCTAssertFalse(Write((char *)ptr + newSize - 1 + pageSize, 0), @"Shouldn't be able to write past the end of the allocation");
        }];
    }
}

- (void)testNonReallocationResizeZeroing {
    MAParanoidAllocator *allocator = [[MAParanoidAllocator alloc] initWithSize: 2];
    [allocator write: ^(void *ptr) {
        ((char *)ptr)[1] = 1;
    }];
    [allocator read: ^(const void *ptr) {
        XCTAssertEqual(((const char *)ptr)[1], (char)1, @"Buffer should contain 1 after writing it");
    }];
    [allocator setSize: 1];
    [allocator setSize: 2];
    [allocator read: ^(const void *ptr) {
        XCTAssertEqual(((const char *)ptr)[1], (char)0, @"Freshly resized buffer should contain zeroes");
    }];
}

@end
