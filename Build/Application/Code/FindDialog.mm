/*!	\file FindDialog.mm
	\brief Used to perform searches in the scrollback
	buffers of terminal windows.
*/
/*###############################################################

	MacTerm
		© 1998-2014 by Kevin Grant.
		© 2001-2003 by Ian Anderson.
		© 1986-1994 University of Illinois Board of Trustees
		(see About box for full list of U of I contributors).
	
	This program is free software; you can redistribute it or
	modify it under the terms of the GNU General Public License
	as published by the Free Software Foundation; either version
	2 of the License, or (at your option) any later version.
	
	This program is distributed in the hope that it will be
	useful, but WITHOUT ANY WARRANTY; without even the implied
	warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
	PURPOSE.  See the GNU General Public License for more
	details.
	
	You should have received a copy of the GNU General Public
	License along with this program; if not, write to:
	
		Free Software Foundation, Inc.
		59 Temple Place, Suite 330
		Boston, MA  02111-1307
		USA

###############################################################*/

#import "FindDialog.h"
#import <UniversalDefines.h>

// standard-C includes
#import <climits>

// standard-C++ includes
#import <vector>

// Mac includes
#import <Cocoa/Cocoa.h>
#import <objc/objc-runtime.h>

// library includes
#import <AlertMessages.h>
#import <CFRetainRelease.h>
#import <CocoaAnimation.h>
#import <CocoaBasic.h>
#import <CocoaExtensions.objc++.h>
#import <CocoaFuture.objc++.h>
#import <Console.h>
#import <Popover.objc++.h>
#import <PopoverManager.objc++.h>

// application includes
#import "Commands.h"
#import "ConstantsRegistry.h"
#import "HelpSystem.h"
#import "SessionFactory.h"
#import "Terminal.h"
#import "TerminalView.h"
#import "UIStrings.h"



#pragma mark Types

/*!
Manages the Find user interface.
*/
@interface FindDialog_Handler : NSObject< FindDialog_ViewManagerChannel, PopoverManager_Delegate > //{
{
	FindDialog_Ref					selfRef;			// identical to address of structure, but typed as ref
	FindDialog_ViewManager*			viewMgr;			// loads the Find interface
	Popover_Window*					containerWindow;	// holds the Find dialog view
	NSView*							managedView;		// the view that implements the majority of the interface
	TerminalWindowRef				terminalWindow;		// the terminal window for which this dialog applies
	PopoverManager_Ref				popoverMgr;			// manages common aspects of popover window behavior
	FindDialog_CloseNotifyProcPtr	closeNotifyProc;	// routine to call when the dialog is dismissed
	FindDialog_Options				cachedOptions;		// options set when the user interface is closed
@private
	NSMutableArray*					_historyArray;
}

// class methods
	+ (FindDialog_Handler*)
	viewHandlerFromRef:(FindDialog_Ref)_;

// initializers
	- (id)
	initForTerminalWindow:(TerminalWindowRef)_
	notificationProc:(FindDialog_CloseNotifyProcPtr)_
	previousSearches:(NSMutableArray*)_
	initialOptions:(FindDialog_Options)_;

// new methods
	- (void)
	clearSearchHighlightingInContext:(FindDialog_SearchContext)_;
	- (void)
	display;
	- (unsigned long)
	initiateSearchFor:(NSString*)_
	ignoringCase:(BOOL)_
	allTerminals:(BOOL)_
	notFinal:(BOOL)_
	didSearch:(BOOL*)_;
	- (void)
	remove;
	- (void)
	zoomToSearchResults;

// accessors
	- (FindDialog_Options)
	cachedOptions;
	@property (strong) NSMutableArray*
	historyArray;
	- (TerminalWindowRef)
	terminalWindow;

// FindDialog_ViewManagerChannel
	- (void)
	findDialog:(FindDialog_ViewManager*)_
	didLoadManagedView:(NSView*)_;
	- (void)
	findDialog:(FindDialog_ViewManager*)_
	clearSearchHighlightingInContext:(FindDialog_SearchContext)_;
	- (void)
	findDialog:(FindDialog_ViewManager*)_
	didSearchInManagedView:(NSView*)_
	withQuery:(NSString*)_;
	- (void)
	findDialog:(FindDialog_ViewManager*)_
	didFinishUsingManagedView:(NSView*)_
	acceptingSearch:(BOOL)_
	finalOptions:(FindDialog_Options)_;

// PopoverManager_Delegate
	- (NSPoint)
	idealAnchorPointForParentWindowFrame:(NSRect)_;
	- (Popover_Properties)
	idealArrowPositionForParentWindowFrame:(NSRect)_;
	- (NSSize)
	idealSize;

@end //}


namespace {

typedef std::vector< Terminal_RangeDescription >	My_TerminalRangeList;

} // anonymous namespace



#pragma mark Public Methods

/*!
Creates a Find window attached to the specified terminal
window, which is also set to search that terminal window.

Display the window with FindDialog_Display().  The user
can close the window at any time, but the Find Dialog
reference remains valid until you release it with a call
to FindDialog_Dispose().  Your close notification routine
may invoke APIs like FindDialog_ReturnOptions() to query
the post-closing state of the window.

(3.0)
*/
FindDialog_Ref
FindDialog_New  (TerminalWindowRef				inTerminalWindow,
				 FindDialog_CloseNotifyProcPtr	inCloseNotifyProcPtr,
				 CFMutableArrayRef				inoutQueryStringHistory,
				 FindDialog_Options				inFlags)
{
	FindDialog_Ref	result = nullptr;
	
	
	result = (FindDialog_Ref)[[FindDialog_Handler alloc]
								initForTerminalWindow:inTerminalWindow notificationProc:inCloseNotifyProcPtr
														previousSearches:(NSMutableArray*)inoutQueryStringHistory
														initialOptions:inFlags];
	return result;
}// New


/*!
Releases the underlying data structure for a Find dialog.

(3.0)
*/
void
FindDialog_Dispose	(FindDialog_Ref*	inoutDialogPtr)
{
	FindDialog_Handler*		ptr = [FindDialog_Handler viewHandlerFromRef:*inoutDialogPtr];
	
	
	[ptr release];
}// Dispose


/*!
This method displays and handles events in the
Find dialog box.  When the user clicks a button
in the dialog, its disposal callback is invoked.

(3.0)
*/
void
FindDialog_Display	(FindDialog_Ref		inDialog)
{
	FindDialog_Handler*		ptr = [FindDialog_Handler viewHandlerFromRef:inDialog];
	
	
	if (nullptr == ptr)
	{
		Alert_ReportOSStatus(paramErr);
	}
	else
	{
		// load the view asynchronously and eventually display it in a window
		[ptr display];
	}
}// Display


/*!
Hides the Find dialog.  It can be redisplayed at any
time by calling FindDialog_Display() again.

(4.0)
*/
void
FindDialog_Remove	(FindDialog_Ref		inDialog)
{
	FindDialog_Handler*		ptr = [FindDialog_Handler viewHandlerFromRef:inDialog];
	
	
	[ptr remove];
}// Remove


/*!
Returns a set of flags indicating whether or not certain
options are enabled for the specified dialog.  This is
only guaranteed to be accurate from within a close
notification routine (after the user interface is hidden);
if the dialog is open this will not necessarily reflect
the current state that the user has set up.

If there are no options enabled, the result will be
"kFindDialog_OptionsAllOff".

(3.0)
*/
FindDialog_Options
FindDialog_ReturnOptions	(FindDialog_Ref		inDialog)
{
	FindDialog_Handler*		ptr = [FindDialog_Handler viewHandlerFromRef:inDialog];
	FindDialog_Options		result = kFindDialog_OptionsAllOff;
	
	
	if (nullptr != ptr)
	{
		result = [ptr cachedOptions];
	}
	return result;
}// ReturnOptions


/*!
Returns a reference to the terminal window that this
dialog is attached to.

(3.0)
*/
TerminalWindowRef
FindDialog_ReturnTerminalWindow		(FindDialog_Ref		inDialog)
{
	FindDialog_Handler*		ptr = [FindDialog_Handler viewHandlerFromRef:inDialog];
	TerminalWindowRef		result = nullptr;
	
	
	if (nullptr != ptr)
	{
		result = [ptr terminalWindow];
	}
	return result;
}// ReturnTerminalWindow


/*!
The default handler for closing a search dialog.

(3.0)
*/
void
FindDialog_StandardCloseNotifyProc		(FindDialog_Ref		UNUSED_ARGUMENT(inDialogThatClosed))
{
	// do nothing
}// StandardCloseNotifyProc


#pragma mark Internal Methods


@implementation FindDialog_Handler


@synthesize historyArray = _historyArray;


/*!
Converts from the opaque reference type to the internal type.

(4.0)
*/
+ (FindDialog_Handler*)
viewHandlerFromRef:(FindDialog_Ref)		aRef
{
	return (FindDialog_Handler*)aRef;
}// viewHandlerFromRef


/*!
Designated initializer.

The specified array of previous search strings is held only
by weak reference and should not be deallocated until after
this class instance is destroyed.

(4.0)
*/
- (id)
initForTerminalWindow:(TerminalWindowRef)			aTerminalWindow
notificationProc:(FindDialog_CloseNotifyProcPtr)	aProc
previousSearches:(NSMutableArray*)					aStringArray
initialOptions:(FindDialog_Options)					options
{
	self = [super init];
	if (nil != self)
	{
		self->selfRef = (FindDialog_Ref)self;
		self->viewMgr = nil;
		self->containerWindow = nil;
		self->managedView = nil;
		self->terminalWindow = aTerminalWindow;
		self->popoverMgr = nullptr;
		self->closeNotifyProc = aProc;
		assert(nil != aStringArray);
		self->_historyArray = [aStringArray retain];
		self->cachedOptions = options;
	}
	return self;
}// initForTerminalWindow:notificationProc:previousSearches:initialOptions:


/*!
Destructor.

(4.0)
*/
- (void)
dealloc
{
	[_historyArray release];
	[containerWindow release];
	[viewMgr release];
	if (nullptr != popoverMgr)
	{
		PopoverManager_Dispose(&popoverMgr);
	}
	[super dealloc];
}// dealloc


/*!
Updates a terminal view so that previously-found words are no
longer highlighted.

(4.1)
*/
- (void)
clearSearchHighlightingInContext:(FindDialog_SearchContext)		aContext
{
	if (kFindDialog_SearchContextLocal == aContext)
	{
		TerminalWindowRef		targetWindow = [self terminalWindow];
		
		
		if (TerminalWindow_IsValid(targetWindow))
		{
			TerminalViewRef		view = TerminalWindow_ReturnViewWithFocus(targetWindow);
			
			
			// remove highlighting from any previous searches
			TerminalView_FindNothing(view);
		}
	}
	else
	{
		SessionFactory_TerminalWindowList const&	searchedWindows = SessionFactory_ReturnTerminalWindowList();
		
		
		for (auto terminalWindowRef : searchedWindows)
		{
			if (TerminalWindow_IsValid(terminalWindowRef))
			{
				TerminalViewRef		view = TerminalWindow_ReturnViewWithFocus(terminalWindowRef);
				
				
				// remove highlighting from any previous searches
				TerminalView_FindNothing(view);
			}
		}
	}
}// clearSearchHighlightingInContext:


/*!
Creates the Find view asynchronously; when the view is ready,
it calls "findDialog:didLoadManagedView:".

(4.0)
*/
- (void)
display
{
	if (nil == self->viewMgr)
	{
		// no focus is done the first time because this is
		// eventually done in "findDialog:didLoadManagedView:"
		self->viewMgr = [[FindDialog_ViewManager alloc]
							initForTerminalWindow:[self terminalWindow] responder:self
													initialOptions:self->cachedOptions];
	}
	else
	{
		// window is already loaded, just activate it
		PopoverManager_DisplayPopover(self->popoverMgr);
	}
}// display


/*!
Starts a (synchronous) search of the focused terminal screen.
Returns the number of matches.

If "isNotFinal" is YES, certain optimizations are made (mostly
heuristics based on the nature of the query).  If the query
looks like it might be expensive, this function automatically
avoids initiating the search, to keep the user interface very
responsive.  Always set "isNotFinal" to NO for final queries,
i.e. those that cause the dialog to close and results to be
permanently highlighted.  The flag "outDidSearch" is set to
YES if the search actually occurred.

(4.0)
*/
- (unsigned long)
initiateSearchFor:(NSString*)	queryString
ignoringCase:(BOOL)				ignoreCase
allTerminals:(BOOL)				allTerminals
notFinal:(BOOL)					isNotFinal
didSearch:(BOOL*)				outDidSearch
{
	CFStringRef					searchQueryCFString = BRIDGE_CAST(queryString, CFStringRef);
	CFIndex						searchQueryLength = 0;
	FindDialog_SearchContext	searchContext = (YES == allTerminals)
												? kFindDialog_SearchContextGlobal
												: kFindDialog_SearchContextLocal;
	unsigned long				result = 0;
	
	
	*outDidSearch = YES; // initially...
	
	searchQueryLength = (nullptr == searchQueryCFString) ? 0 : CFStringGetLength(searchQueryCFString);
	if (0 == searchQueryLength)
	{
		// special case; empty queries always “succeed” but deselect everything
		[self clearSearchHighlightingInContext:searchContext];
		*outDidSearch = NO;
	}
	else
	{
		Boolean										queryOK = true;
		SessionFactory_TerminalWindowList			singleWindowList;
		SessionFactory_TerminalWindowList const*	searchedWindows = &singleWindowList;
		
		
		if (isNotFinal)
		{
			queryOK = false; // initially...
			if (STATIC_CAST(searchQueryLength, UInt32) >= 2/* arbitrary */)
			{
				CFRetainRelease		searchQueryMutableCopy(CFStringCreateMutableCopy(kCFAllocatorDefault, searchQueryLength,
																						searchQueryCFString),
															true/* is retained */);
				
				
				// note that the mutable copy is ONLY used for these heuristics,
				// and the search itself is conducted with the original query only
				if (searchQueryMutableCopy.exists())
				{
					// do not dynamically search for long strings of only whitespace;
					// they will match almost the entire terminal buffer, and will
					// surely bring the CPU to its knees
					CFStringTrimWhitespace(searchQueryMutableCopy.returnCFMutableStringRef());
					queryOK = (CFStringGetLength(searchQueryMutableCopy.returnCFStringRef()) > 0);
				}
			}
		}
		
		if (false == queryOK)
		{
			// cannot find a query string; abort the search
			singleWindowList.clear();
			*outDidSearch = NO;
		}
		else if (allTerminals)
		{
			// search more than one terminal and highlight results in all!
			searchedWindows = &(SessionFactory_ReturnTerminalWindowList());
		}
		else
		{
			// search only the active session
			singleWindowList.push_back([self terminalWindow]);
		}
		
		// remove highlighting from any previous searches
		[self clearSearchHighlightingInContext:searchContext];
		
		for (auto terminalWindowRef : *searchedWindows)
		{
			TerminalViewRef			view = TerminalWindow_ReturnViewWithFocus(terminalWindowRef);
			TerminalScreenRef		screen = TerminalWindow_ReturnScreenWithFocus(terminalWindowRef);
			My_TerminalRangeList	searchResults;
			Terminal_SearchFlags	flags = 0;
			Terminal_Result			searchStatus = kTerminal_ResultOK;
			
			
			// initiate synchronous (should be asynchronous!) search
			if ((nullptr != searchQueryCFString) && (searchQueryLength > 0))
			{
				// configure search
				unless (ignoreCase)
				{
					flags |= kTerminal_SearchFlagsCaseSensitive;
				}
				
				// initiate synchronous (should it be asynchronous?) search
				searchStatus = Terminal_Search(screen, searchQueryCFString, flags, searchResults);
				if (kTerminal_ResultOK == searchStatus)
				{
					if (false == searchResults.empty())
					{
						// the count is global (if multi-terminal, reflects results from all terminals)
						result += STATIC_CAST(searchResults.size(), unsigned long);
						
						// highlight search results
						for (auto rangeDesc : searchResults)
						{
							TerminalView_CellRange		highlightRange;
							TerminalView_Result			viewResult = kTerminalView_ResultOK;
							
							
							// translate this result range into cell anchors for highlighting
							viewResult = TerminalView_TranslateTerminalScreenRange(view, rangeDesc, highlightRange);
							if (kTerminalView_ResultOK == viewResult)
							{
								TerminalView_FindVirtualRange(view, highlightRange);
							}
						}
					}
				}
			}
		}
	}
	
	return result;
}// initiateSearchFor:ignoringCase:allTerminals:notFinal:didSearch:


/*!
Hides the popover.  It can be shown again at any time
using the "display" method.

(4.0)
*/
- (void)
remove
{
	if (nil != self->popoverMgr)
	{
		PopoverManager_RemovePopover(self->popoverMgr);
	}
}// remove


/*!
Highlights the location of the first search result.

This is in an Objective-C method so that it can be
conveniently invoked after a short delay.

(4.0)
*/
- (void)
zoomToSearchResults
{
	// show the user where the text is
	TerminalView_ZoomToSearchResults(TerminalWindow_ReturnViewWithFocus([self terminalWindow]));
}// zoomToSearchResults


#pragma mark Accessors


/*!
Accessor.

(4.0)
*/
- (FindDialog_Options)
cachedOptions
{
	return cachedOptions;
}// cachedOptions


/*!
Accessor.

(4.0)
*/
- (TerminalWindowRef)
terminalWindow
{
	return terminalWindow;
}// terminalWindow


#pragma mark FindDialog_ViewManagerChannel


/*!
Called when a FindDialog_ViewManager has finished loading
and initializing its view; responds by displaying the view
in a window and giving it keyboard focus.

Since this may be invoked multiple times, the window is
only created during the first invocation.

(4.0)
*/
- (void)
findDialog:(FindDialog_ViewManager*)	aViewMgr
didLoadManagedView:(NSView*)			aManagedView
{
	self->managedView = aManagedView;
	if (nil == self->containerWindow)
	{
		NSWindow*	parentWindow = TerminalWindow_ReturnNSWindow([self terminalWindow]);
		
		
		self->containerWindow = [[Popover_Window alloc] initWithView:aManagedView
																		attachedToPoint:NSZeroPoint/* see delegate */
																		inWindow:parentWindow];
		[self->containerWindow setReleasedWhenClosed:NO];
		
		CocoaBasic_ApplyStandardStyleToPopover(self->containerWindow, false/* has arrow */);
		self->popoverMgr = PopoverManager_New(self->containerWindow, [aViewMgr logicalFirstResponder],
												self/* delegate */, kPopoverManager_AnimationTypeNone,
												TerminalWindow_ReturnWindow([self terminalWindow]));
		PopoverManager_DisplayPopover(self->popoverMgr);
	}
}// findDialog:didLoadManagedView:


/*!
Called when highlighting should be removed.

(4.1)
*/
- (void)
findDialog:(FindDialog_ViewManager*)							aViewMgr
clearSearchHighlightingInContext:(FindDialog_SearchContext)		aContext
{
#pragma unused(aViewMgr)
	[self clearSearchHighlightingInContext:aContext];
}// findDialog:clearSearchHighlightingInContext:


/*!
Called when the user has triggered a search, either by
starting to type text or hitting the default button.
The specified string is for convenience, it should be
equivalent to "[aViewMgr searchText]".

(4.0)
*/
- (void)
findDialog:(FindDialog_ViewManager*)	aViewMgr
didSearchInManagedView:(NSView*)		aManagedView
withQuery:(NSString*)					searchText
{
#pragma unused(aManagedView)
	BOOL			didSearch = NO;
	unsigned long	matchCount = [self initiateSearchFor:searchText
															ignoringCase:aViewMgr.caseInsensitiveSearch
															allTerminals:aViewMgr.multiTerminalSearch
															notFinal:YES didSearch:&didSearch];
	
	
	[aViewMgr updateUserInterfaceWithMatches:matchCount didSearch:didSearch];
}// findDialog:didSearchInManagedView:withQuery:


/*!
Called when the user has taken some action that would
complete his or her interaction with the view; a
sensible response is to close any containing window.
If the search is accepted, initiate one final search;
otherwise, undo any highlighting and restore the search
results that were in effect before the Find dialog was
opened.

(4.0)
*/
- (void)
findDialog:(FindDialog_ViewManager*)	aViewMgr
didFinishUsingManagedView:(NSView*)		aManagedView
acceptingSearch:(BOOL)					acceptedSearch
finalOptions:(FindDialog_Options)		options
{
#pragma unused(aViewMgr, aManagedView)
	NSString*	searchText = [aViewMgr searchText];
	BOOL		caseInsensitive = aViewMgr.caseInsensitiveSearch;
	BOOL		multiTerminal = aViewMgr.multiTerminalSearch;
	
	
	self->cachedOptions = options;
	
	// make search history persistent for the window
	NSMutableArray*		recentSearchesArray = self.historyArray;
	if (nil != searchText)
	{
		[recentSearchesArray removeObject:searchText]; // remove any older copy of this search phrase
		[recentSearchesArray insertObject:searchText atIndex:0];
		[[aViewMgr searchField] setRecentSearches:[recentSearchesArray copy]];
	}
	
	// hide the popover
	[self remove];
	
	// highlight search results
	if (acceptedSearch)
	{
		BOOL	didSearch = NO;
		
		
		UNUSED_RETURN(unsigned long)[self initiateSearchFor:searchText ignoringCase:caseInsensitive allTerminals:multiTerminal
															notFinal:NO didSearch:&didSearch];
		
		// show the user where the text is; delay this slightly to avoid
		// animation interference caused by the closing of the popover
		[self performSelector:@selector(zoomToSearchResults) withObject:nil afterDelay:0.1/* seconds */];
	}
	else
	{
		// user cancelled; try to return to the previous search
		if ((nil != recentSearchesArray) && ([recentSearchesArray count] > 0))
		{
			BOOL	didSearch = NO;
			
			
			searchText = STATIC_CAST([recentSearchesArray objectAtIndex:0], NSString*);
			UNUSED_RETURN(unsigned long)[self initiateSearchFor:searchText ignoringCase:caseInsensitive allTerminals:NO
																notFinal:NO didSearch:&didSearch];
		}
		else
		{
			// no previous search available; remove all highlighting
			[self clearSearchHighlightingInContext:((YES == multiTerminal)
													? kFindDialog_SearchContextGlobal
													: kFindDialog_SearchContextLocal)];
		}
	}
	
	// notify of close
	if (nullptr != self->closeNotifyProc)
	{
		FindDialog_InvokeCloseNotifyProc(self->closeNotifyProc, self->selfRef);
	}
}// findDialog:didFinishUsingManagedView:acceptingSearch:finalOptions:


#pragma mark PopoverManager_Delegate


/*!
Returns the location (relative to the window) where the
popover’s arrow tip should appear.  The location of the
popover itself depends on the arrow placement chosen by
"idealArrowPositionForParentWindowFrame:".

(4.0)
*/
- (NSPoint)
idealAnchorPointForParentWindowFrame:(NSRect)	parentFrame
{
	NSPoint		result = NSZeroPoint;
	
	
	if (nil != self->managedView)
	{
		NSRect		managedViewFrame = [self->managedView frame];
		
		
		result = NSMakePoint(parentFrame.size.width - managedViewFrame.size.width - 16.0/* arbitrary */, 0.0);
	}
	return result;
}// idealAnchorPointForParentWindowFrame:


/*!
Returns arrow placement information for the popover.

(4.0)
*/
- (Popover_Properties)
idealArrowPositionForParentWindowFrame:(NSRect)		parentFrame
{
#pragma unused(parentFrame)
	Popover_Properties	result = kPopover_PropertyArrowBeginning | kPopover_PropertyPlaceFrameAboveArrow;
	
	
	return result;
}// idealArrowPositionForParentWindowFrame:


/*!
Returns the initial size for the popover.

(4.0)
*/
- (NSSize)
idealSize
{
	NSSize		result = NSZeroSize;
	
	
	if (nil != self->containerWindow)
	{
		NSRect		frameRect = [self->containerWindow frameRectForViewRect:[self->managedView frame]];
		
		
		result = frameRect.size;
	}
	return result;
}// idealSize


@end // FindDialog_Handler


@implementation FindDialog_SearchField


#pragma mark NSNibAwaking


/*!
Checks IBOutlet bindings.

(4.1)
*/
- (void)
awakeFromNib
{
	assert(nil != self.delegate); // in this case the delegate is pretty important
	assert(nil != viewManager);
}// awakeFromNib


@end // FindDialog_SearchField


@implementation FindDialog_ViewManager


@synthesize searchProgressHidden = _searchProgressHidden;
@synthesize searchText = _searchText;
@synthesize statusText = _statusText;
@synthesize successfulSearch = _successfulSearch;


/*!
Designated initializer.

(4.0)
*/
- (id)
initForTerminalWindow:(TerminalWindowRef)			aTerminalWindow
responder:(id< FindDialog_ViewManagerChannel >)		aResponder
initialOptions:(FindDialog_Options)					options
{
	self = [super init];
	if (nil != self)
	{
		responder = aResponder;
		terminalWindow = aTerminalWindow;
		_caseInsensitiveSearch = (0 != (options & kFindDialog_OptionCaseInsensitive));
		_multiTerminalSearch = (0 != (options & kFindDialog_OptionAllOpenTerminals));
		_searchProgressHidden = YES;
		_successfulSearch = YES;
		_searchText = [@"" retain];
		_statusText = [@"" retain];
		
		// it is necessary to capture and release all top-level objects here
		// so that "self" can actually be deallocated; otherwise, the implicit
		// retain-count of 1 on each top-level object prevents deallocation
		{
			NSArray*	objects = nil;
			NSNib*		loader = [[NSNib alloc] initWithNibNamed:@"FindDialogCocoa" bundle:nil];
			BOOL		loadOK = [loader instantiateNibWithOwner:self topLevelObjects:&objects];
			
			
			[loader release];
			if (NO == loadOK)
			{
				[self release];
				return nil;
			}
			[objects makeObjectsPerformSelector:@selector(release)];
		}
	}
	return self;
}// initForTerminalWindow:responder:initialOptions:


/*!
Destructor.

(4.0)
*/
- (void)
dealloc
{
	[_searchText release];
	[_statusText release];
	[super dealloc];
}// dealloc


#pragma mark New Methods


/*!
Returns the view that a window ought to focus first
using NSWindow’s "makeFirstResponder:".

(4.0)
*/
- (NSView*)
logicalFirstResponder
{
	return [self searchField];
}// logicalFirstResponder


/*!
Responds to a click in the help button.

(4.0)
*/
- (IBAction)
performContextSensitiveHelp:(id)	sender
{
#pragma unused(sender)
	UNUSED_RETURN(HelpSystem_Result)HelpSystem_DisplayHelpFromKeyPhrase(kHelpSystem_KeyPhraseFind);
}// performContextSensitiveHelp:


/*!
Cancels the dialog and restores any previous search
results in the target window.

IMPORTANT:	It is appropriate at this time for the
			responder object to release itself (and
			this object).

(4.0)
*/
- (IBAction)
performCloseAndRevert:(id)	sender
{
#pragma unused(sender)
	FindDialog_Options		options = kFindDialog_OptionsAllOff;
	
	
	if (self.caseInsensitiveSearch)
	{
		options |= kFindDialog_OptionCaseInsensitive;
	}
	[self->responder findDialog:self didFinishUsingManagedView:self->managedView
										acceptingSearch:NO finalOptions:options];
}// performCloseAndRevert:


/*!
Unlike "performSearch:", which can begin a search while
leaving the window open, this method will close the
Find dialog.

IMPORTANT:	It is appropriate at this time for the
			responder object to release itself (and
			this object).

(4.0)
*/
- (IBAction)
performCloseAndSearch:(id)	sender
{
#pragma unused(sender)
	NSString*				queryText = (nil == _searchText)
										? @""
										: [NSString stringWithString:_searchText];
	FindDialog_Options		options = kFindDialog_OptionsAllOff;
	
	
	if (self.caseInsensitiveSearch)
	{
		options |= kFindDialog_OptionCaseInsensitive;
	}
	[self->responder findDialog:self didSearchInManagedView:self->managedView withQuery:queryText];
	[self->responder findDialog:self didFinishUsingManagedView:self->managedView
										acceptingSearch:YES finalOptions:options];
}// performCloseAndSearch:


/*!
Initiates a search using the keywords currently entered
in the field.  See also "performCloseAndSearch:".

(4.0)
*/
- (IBAction)
performSearch:(id)	sender
{
#pragma unused(sender)
	NSString*	queryText = (nil == _searchText)
							? @""
							: [NSString stringWithString:_searchText];
	
	
	self.statusText = @"";
	self.searchProgressHidden = NO;
	[self->responder findDialog:self didSearchInManagedView:self->managedView withQuery:queryText];
}// performSearch:


/*!
Returns the view that contains the search query text and
a menu of recent searches.

(4.0)
*/
- (NSSearchField*)
searchField
{
	return searchField;
}// searchField


/*!
This should be called by a responder after it attempts to
continue searching.

If the search did not occur yet ("didSearch:), the UI status
does not show any matches or any errors.  Otherwise, include
the number of times the query matched: if the count is zero,
the interface shows an error; otherwise, it displays the
number of matches to the user.

There is no need to call "setSearchProgressHidden:" or any
similar methods; this single call will clean up the UI.

(4.0)
*/
- (void)
updateUserInterfaceWithMatches:(unsigned long)	matchCount
didSearch:(BOOL)								didSearch
{
	UIStrings_Result	stringResult = kUIStrings_ResultOK;
	CFStringRef			statusCFString = nullptr;
	BOOL				releaseStatusString = NO;
	
	
	if (NO == didSearch)
	{
		statusCFString = CFSTR("");
	}
	else if (0 == matchCount)
	{
		stringResult = UIStrings_Copy(kUIStrings_TerminalSearchNothingFound, statusCFString);
		if (false == stringResult.ok())
		{
			statusCFString = nullptr;
		}
		else
		{
			releaseStatusString = YES;
		}
	}
	else
	{
		CFStringRef		templateCFString = nullptr;
		
		
		stringResult = UIStrings_Copy(kUIStrings_TerminalSearchNumberOfMatches, templateCFString);
		if (stringResult.ok())
		{
			statusCFString = CFStringCreateWithFormat(kCFAllocatorDefault, nullptr/* options */, templateCFString,
														matchCount);
			releaseStatusString = YES;
			CFRelease(templateCFString), templateCFString = nullptr;
		}
	}
	
	// update settings; due to bindings, the user interface will automatically be updated
	self.statusText = BRIDGE_CAST(statusCFString, NSString*);
	self.searchProgressHidden = YES;
	self.successfulSearch = ((matchCount > 0) || ([_searchText length] <= 1));
	
	if ((nullptr != statusCFString) && (releaseStatusString))
	{
		CFRelease(statusCFString), statusCFString = nullptr;
	}
}// updateUserInterfaceWithMatches:didSearch:


#pragma mark Accessors


/*!
Accessor.

(4.0)
*/
- (BOOL)
caseInsensitiveSearch
{
	return _caseInsensitiveSearch;
}
- (void)
setCaseInsensitiveSearch:(BOOL)		isCaseInsensitive
{
	if (_caseInsensitiveSearch != isCaseInsensitive)
	{
		_caseInsensitiveSearch = isCaseInsensitive;
		[self performSearch:NSApp];
	}
}// setCaseInsensitiveSearch:


/*!
Accessor.

(4.0)
*/
- (BOOL)
multiTerminalSearch
{
	return _multiTerminalSearch;
}
- (void)
setMultiTerminalSearch:(BOOL)	isMultiTerminal
{
	if (_multiTerminalSearch != isMultiTerminal)
	{
		_multiTerminalSearch = isMultiTerminal;
		
		// if the setting is being turned off, erase the
		// search highlighting from other windows (this will
		// not happen automatically once the search flag is
		// restricted to a single window)
		if (NO == _multiTerminalSearch)
		{
			[self->responder findDialog:self clearSearchHighlightingInContext:kFindDialog_SearchContextGlobal];
		}
		
		// update search results of current terminal window and
		// (if multi-terminal mode) all other terminal windows
		[self performSearch:NSApp];
	}
}// setMultiTerminalSearch:


#pragma mark NSKeyValueObservingCustomization


/*!
Returns true for keys that manually notify observers
(through "willChangeValueForKey:", etc.).

(4.0)
*/
+ (BOOL)
automaticallyNotifiesObserversForKey:(NSString*)	theKey
{
	BOOL	result = YES;
	SEL		flagSource = NSSelectorFromString([[self class] selectorNameForKeyChangeAutoNotifyFlag:theKey]);
	
	
	if (NULL != class_getClassMethod([self class], flagSource))
	{
		// See selectorToReturnKeyChangeAutoNotifyFlag: for more information on the form of the selector.
		result = [[self performSelector:flagSource] boolValue];
	}
	else
	{
		result = [super automaticallyNotifiesObserversForKey:theKey];
	}
	return result;
}// automaticallyNotifiesObserversForKey:


#pragma mark NSNibAwaking


/*!
Handles initialization that depends on user interface
elements being properly set up.  (Everything else is just
done in "init".)

(4.0)
*/
- (void)
awakeFromNib
{
	// NOTE: superclass does not implement "awakeFromNib", otherwise it should be called here
	assert(nil != managedView);
	assert(nil != searchField);
	
	[self->responder findDialog:self didLoadManagedView:self->managedView];
}// awakeFromNib


#pragma mark NSTextFieldDelegate


/*!
Responds to cancellation by closing the panel and responds to
(say) a Return by closing the panel but preserving the current
search term and search options.  Ignores other key events.

(4.1)
*/
- (BOOL)
control:(NSControl*)		aControl
textView:(NSTextView*)		aTextView
doCommandBySelector:(SEL)	aSelector
{
	BOOL	result = NO;
	
	
	// this delegate is not designed to manage other fields...
	assert(self->searchField == aControl);
	
	if (@selector(cancelOperation:) == aSelector)
	{
		// only cancel if the field is empty
		if (0 == [[aTextView string] length])
		{
			[self performCloseAndRevert:self];
			result = YES;
		}
	}
	else if (@selector(insertNewline:) == aSelector)
	{
		[self performCloseAndSearch:self];
		result = YES;
	}
	
	return result;
}// control:textView:doCommandBySelector:


@end // FindDialog_ViewManager

// BELOW IS REQUIRED NEWLINE TO END FILE
