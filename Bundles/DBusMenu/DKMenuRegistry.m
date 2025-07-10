/** A registry object for exporting the main menu to D-Bus
   Copyright (C) 2013 Free Software Foundation, Inc.

   Written by:  Niels Grewe <niels.grewe@halbordnung.de>
   Created: December 2013

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Lesser General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Lesser General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 51 Franklin Street, Fifth Floor,
   Boston, MA 02111 USA.

   <title>DKMenuRegistry reference</title>
   */

#import <Foundation/NSObject.h>
#import "DKMenuRegistry.h"
#import <Foundation/NSIndexSet.h>
#import <AppKit/NSApplication.h>
#import <AppKit/NSMenu.h>
#import <AppKit/NSWindow.h>
#import <GNUstepGUI/GSDisplayServer.h>
#import <DBusKit/DBusKit.h>
#import "com_canonical_AppMenu_Registrar.h"
#import "DKMenuProxy.h"
#import <dispatch/dispatch.h>

@interface NSObject (PrivateStuffDoNotUse)
- (id) _objectPathNodeAtPath: (NSString*)string;
- (void)_setObject: (id)obj atPath: (NSString*)path; 
@end

@interface DKProxy (PrivateStuffDoNotUse)
- (BOOL)_loadIntrospectionFromFile: (NSString*)path;
@end

@interface DKMenuRegistry ()
{
  dispatch_queue_t registryQueue;
  dispatch_group_t setupGroup;
}
@end

@implementation DKMenuRegistry

- (id)init
{
  DKPort *sp = [[[DKPort alloc] initWithRemote: @"com.canonical.AppMenu.Registrar"] autorelease];
  NSConnection *connection = [NSConnection connectionWithReceivePort: [DKPort port]
                                                            sendPort: sp];
  if (nil == (self = [super init]))
  {
    return nil;
  }
  
  // Create dedicated queue for registry operations
  registryQueue = dispatch_queue_create("org.gnustep.dbuskit.registry", DISPATCH_QUEUE_SERIAL);
  setupGroup = dispatch_group_create();
  
  registrar = [(id)[connection proxyAtPath: @"/com/canonical/AppMenu/Registrar"] retain];

  if (nil == registrar)
  {
    NSDebugMLLog(@"DKMenu", @"No connection to menu server.");
    [self release];
    return nil;
  }

  windowNumbers = [NSMutableIndexSet new];
  return self;
}

- (void)dealloc
{
  [registrar release];
  [windowNumbers release];
  [busProxy release];
  [menuProxy release];
  if (registryQueue) {
    dispatch_release(registryQueue);
  }
  if (setupGroup) {
    dispatch_release(setupGroup);
  }
  [super dealloc];
}


- (DKProxy*)busProxy
{
  return busProxy;
}

+ (id)sharedRegistry
{
  // TODO: Actually make it a singleton
  return [self new];
}

- (void)_registerWindowSafely:(NSWindow *)window
{
  dispatch_async(registryQueue, ^{
    if (busProxy == nil)
    {
      NSLog(@"[DKMenuRegistry] Skipping RegisterWindow — no busProxy available.");
      return;
    }

    int internalNumber = [window windowNumber];
    GSDisplayServer *srv = GSServerForWindow(window);
    uint32_t number = (uint32_t)(uintptr_t)[srv windowDevice: internalNumber];
    NSNumber *boxed = [NSNumber numberWithInt: number];

    if ((NO == [windowNumbers containsIndex: number]))
    {
      NSDebugMLLog(@"DKMenu", @"Publishing menu for window %d", number);
      [registrar RegisterWindow: boxed : busProxy];
      [windowNumbers addIndex: number];
    }
  });
}

- (void)setupProxyForMenu: (NSMenu*)menu
{
  dispatch_group_async(setupGroup, registryQueue, ^{
    if (menuProxy != nil)
    {
      NSLog(@"[DKMenuRegistry] Proxy already exists, skipping export.");
      return;
    }

    if (menu == nil || [menu numberOfItems] == 0)
    {
      NSLog(@"[DKMenuRegistry] Not exporting proxy for empty menu.");
      return;
    }

    menuProxy = [[DKMenuProxy alloc] initWithMenu: menu];
    if (menuProxy == nil)
    {
      NSLog(@"[DKMenuRegistry] Failed to create menu proxy.");
      return;
    }

    DKPort *p = (DKPort*)[DKPort port];

    @try
    {
      [p _setObject: menuProxy atPath: @"/org/gnustep/application/mainMenu"];
    }
    @catch (NSException *e)
    {
      NSLog(@"[DKMenuRegistry] Failed to export menu proxy: %@", e.reason);
      [menuProxy release];
      menuProxy = nil;
      return;
    }

    busProxy = [[p _objectPathNodeAtPath: @"/org/gnustep/application/mainMenu"] retain];
    if (busProxy == nil)
    {
      NSLog(@"[DKMenuRegistry] Failed to get bus proxy.");
      [menuProxy release];
      menuProxy = nil;
      return;
    }

    NSBundle *bundle = [NSBundle bundleForClass: [self class]];
    NSString *path = [bundle pathForResource: @"com.canonical.dbusmenu" ofType: @"xml"];
    if (path != nil)
    {
      [busProxy _loadIntrospectionFromFile: path];
    }

    [menuProxy setExported: YES];
    NSDebugMLLog(@"DKMenu", @"Menu proxy setup completed successfully.");
  });
}

- (void)setMenu:(NSMenu *)menu forWindow:(NSWindow *)window
{
  // Setup proxy asynchronously if needed
  if (menuProxy == nil)
  {
    [self setupProxyForMenu: menu];
  }
  else
  {
    // Update existing proxy with new menu
    dispatch_async(registryQueue, ^{
      [menuProxy menuUpdated: menu];
    });
  }

  // Wait for setup to complete, then register window
  dispatch_group_notify(setupGroup, dispatch_get_main_queue(), ^{
    if (menuProxy != nil)
    {
      [self _registerWindowSafely: window];
    }
    else
    {
      NSLog(@"[DKMenuRegistry] Menu proxy was not created — aborting setMenu");
    }
  });
}

@end
