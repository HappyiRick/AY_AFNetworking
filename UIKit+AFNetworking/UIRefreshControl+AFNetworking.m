// UIRefreshControl+AFNetworking.m
//
// Copyright (c) 2011–2016 Alamofire Software Foundation ( http://alamofire.org/ )
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "UIRefreshControl+AFNetworking.h"
#import <objc/runtime.h>

#if TARGET_OS_IOS

#import "AFURLSessionManager.h"

@interface AFRefreshControlNotificationObserver : NSObject
/// 保存要绑定task的刷新控件
@property (readonly, nonatomic, weak) UIRefreshControl *refreshControl;
/// 以指定刷新控件初始化的方法
- (instancetype)initWithActivityRefreshControl:(UIRefreshControl *)refreshControl;
/// 为UIRefreshControl绑定指定的task
- (void)setRefreshingWithStateOfTask:(NSURLSessionTask *)task;

@end

@implementation UIRefreshControl (AFNetworking)

- (AFRefreshControlNotificationObserver *)af_notificationObserver {
    // 先通过关联对象获取为分类创建的属性
    AFRefreshControlNotificationObserver *notificationObserver = objc_getAssociatedObject(self, @selector(af_notificationObserver));
    // 如果属性为空
    if (notificationObserver == nil) {
        // 创建刷新控件通知观察者对象
        notificationObserver = [[AFRefreshControlNotificationObserver alloc] initWithActivityRefreshControl:self];
        // 通过关联对象将创建的对象保存到属性中
        objc_setAssociatedObject(self, @selector(af_notificationObserver), notificationObserver, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return notificationObserver;
}

- (void)setRefreshingWithStateOfTask:(NSURLSessionTask *)task {
    // 获取到刷新控件通知观察者对象并为之绑定task
    [[self af_notificationObserver] setRefreshingWithStateOfTask:task];
}

@end

@implementation AFRefreshControlNotificationObserver

- (instancetype)initWithActivityRefreshControl:(UIRefreshControl *)refreshControl
{
    self = [super init];
    if (self) {
        // 保存控件
        _refreshControl = refreshControl;
    }
    return self;
}

- (void)setRefreshingWithStateOfTask:(NSURLSessionTask *)task {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];

    [notificationCenter removeObserver:self name:AFNetworkingTaskDidResumeNotification object:nil];
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidSuspendNotification object:nil];
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidCompleteNotification object:nil];

    if (task) {
        UIRefreshControl *refreshControl = self.refreshControl;
        // 如果任务状态是正在运行中
        if (task.state == NSURLSessionTaskStateRunning) {
            [refreshControl beginRefreshing];
            // 注册通知监听task的开始、完成和暂停
            [notificationCenter addObserver:self selector:@selector(af_beginRefreshing) name:AFNetworkingTaskDidResumeNotification object:task];
            [notificationCenter addObserver:self selector:@selector(af_endRefreshing) name:AFNetworkingTaskDidCompleteNotification object:task];
            [notificationCenter addObserver:self selector:@selector(af_endRefreshing) name:AFNetworkingTaskDidSuspendNotification object:task];
        } else {
            // 刷新控件停止刷新
            [refreshControl endRefreshing];
        }
    }
}

#pragma mark -

- (void)af_beginRefreshing {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.refreshControl beginRefreshing];
    });
}

- (void)af_endRefreshing {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.refreshControl endRefreshing];
    });
}

#pragma mark -
// 在dealloc中移除刷新
- (void)dealloc {
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidCompleteNotification object:nil];
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidResumeNotification object:nil];
    [notificationCenter removeObserver:self name:AFNetworkingTaskDidSuspendNotification object:nil];
}

@end

#endif
