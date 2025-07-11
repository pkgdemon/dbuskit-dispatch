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
  BOOL proxyCreationInProgress;
}
@end

@implementation DKMenuRegistry

- (id)init
{
  NSLog(@"[DKMenuRegistry] init called");
  
  DKPort *sp = [[[DKPort alloc] initWithRemote: @"com.canonical.AppMenu.Registrar"] autorelease];
  NSConnection *connection = [NSConnection connectionWithReceivePort: [DKPort port]
                                                            sendPort: sp];
  if (nil == (self = [super init]))
  {
    NSLog(@"[DKMenuRegistry] super init failed");
    return nil;
  }
  
  // Create dedicated queue for registry operations
  registryQueue = dispatch_queue_create("org.gnustep.dbuskit.registry", DISPATCH_QUEUE_SERIAL);
  proxyCreationInProgress = NO;
  
  registrar = [(id)[connection proxyAtPath: @"/com/canonical/AppMenu/Registrar"] retain];

  if (nil == registrar)
  {
    NSLog(@"[DKMenuRegistry] No connection to menu server - this is expected if no global menu is running");
    [self release];
    return nil;
  }

  NSLog(@"[DKMenuRegistry] Successfully connected to menu server");
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
  [super dealloc];
}

- (DKProxy*)busProxy
{
  return busProxy;
}

+ (id)sharedRegistry
{
  NSLog(@"[DKMenuRegistry] sharedRegistry called");
  // TODO: Actually make it a singleton
  DKMenuRegistry *registry = [self new];
  if (registry) {
    NSLog(@"[DKMenuRegistry] sharedRegistry created successfully");
  } else {
    NSLog(@"[DKMenuRegistry] sharedRegistry creation failed");
  }
  return registry;
}

- (void)setupProxyForMenu: (NSMenu*)menu
{
  if (menuProxy != nil)
  {
    NSDebugMLLog(@"DKMenu", @"Proxy already exists, updating menu instead.");
    if (menu != nil)
    {
      [menuProxy menuUpdated: menu];
    }
    return;
  }

  if (menu == nil)
  {
    NSDebugMLLog(@"DKMenu", @"Cannot create proxy for nil menu.");
    return;
  }

  // Create proxy directly
  [self _createProxyForMenu: menu];
}

- (void)setMenu:(NSMenu *)menu forWindow:(NSWindow *)window
{
  NSLog(@"[DKMenuRegistry] setMenu:forWindow: called with menu=%@ window=%@", menu, window);
  
  // Simple approach - no complex dispatch
  if (menuProxy == nil && menu != nil)
  {
    NSLog(@"[DKMenuRegistry] Creating new proxy for menu");
    [self _createProxyForMenu: menu];
  }
  else if (menuProxy != nil && menu != nil)
  {
    // Only update if it's actually a different menu
    NSLog(@"[DKMenuRegistry] Checking if menu update needed");
    [menuProxy menuUpdated: menu];
  }
  else if (menu == nil)
  {
    NSLog(@"[DKMenuRegistry] Skipping nil menu");
    return;
  }
  
  // Register window if we have a working proxy
  if (menuProxy != nil && [menuProxy isExported])
  {
    [self _registerWindowSafely: window];
  }
  else
  {
    NSLog(@"[DKMenuRegistry] Deferring window registration - proxy not ready");
  }
}

- (void)_registerWindowSafely:(NSWindow *)window
{
  if (busProxy == nil)
  {
    NSLog(@"[DKMenuRegistry] Skipping RegisterWindow — no busProxy available.");
    return;
  }
  
  if (menuProxy == nil || ![menuProxy isExported])
  {
    NSLog(@"[DKMenuRegistry] Skipping RegisterWindow — menu proxy not ready.");
    return;
  }

  int internalNumber = [window windowNumber];
  GSDisplayServer *srv = GSServerForWindow(window);
  uint32_t number = (uint32_t)(uintptr_t)[srv windowDevice: internalNumber];
  NSNumber *boxed = [NSNumber numberWithInt: number];

  if (![windowNumbers containsIndex: number])
  {
    NSLog(@"[DKMenuRegistry] Publishing menu for window %d", number);
    [windowNumbers addIndex: number];
    
    @try {
      [registrar RegisterWindow: boxed : busProxy];
      NSLog(@"[DKMenuRegistry] Successfully registered window %d", number);
    } @catch (NSException *e) {
      NSLog(@"[DKMenuRegistry] Failed to register window: %@", e.reason);
      [windowNumbers removeIndex: number];
    }
  }
  else
  {
    NSLog(@"[DKMenuRegistry] Window %d already registered", number);
  }
}

- (void)_createProxyForMenu: (NSMenu*)menu
{
  NSLog(@"[DKMenuRegistry] _createProxyForMenu called with menu: %@ (items: %lu)", [menu title], [menu numberOfItems]);
  
  menuProxy = [[DKMenuProxy alloc] initWithMenu: menu];
  if (menuProxy == nil)
  {
    NSLog(@"[DKMenuRegistry] Failed to create menu proxy.");
    return;
  }
  NSLog(@"[DKMenuRegistry] Menu proxy created successfully");

  DKPort *p = (DKPort*)[DKPort port];

  @try
  {
    [p _setObject: menuProxy atPath: @"/org/gnustep/application/mainMenu"];
    NSLog(@"[DKMenuRegistry] Menu proxy exported to D-Bus path");
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
  NSLog(@"[DKMenuRegistry] Bus proxy obtained");

  NSBundle *bundle = [NSBundle bundleForClass: [self class]];
  NSString *path = [bundle pathForResource: @"com.canonical.dbusmenu" ofType: @"xml"];
  if (path != nil)
  {
    [busProxy _loadIntrospectionFromFile: path];
    NSLog(@"[DKMenuRegistry] Introspection loaded from: %@", path);
  }
  else
  {
    NSLog(@"[DKMenuRegistry] Warning: Could not find introspection file");
  }

  [menuProxy setExported: YES];
  NSLog(@"[DKMenuRegistry] Menu proxy setup completed successfully.");
}

@end
