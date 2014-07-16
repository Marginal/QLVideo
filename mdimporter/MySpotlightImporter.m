//
//  MySpotlightImporter.m
//  Video
//
//  Created by Jonathan Harris on 03/07/2014.
//
//

#import "MySpotlightImporter.h"

#define YOUR_STORE_TYPE NSXMLStoreType

@interface MySpotlightImporter ()
@property (nonatomic, strong) NSURL *modelURL;
@property (nonatomic, strong) NSURL *storeURL;
@end

@implementation MySpotlightImporter

@synthesize persistentStoreCoordinator = _persistentStoreCoordinator;
@synthesize managedObjectModel = _managedObjectModel;
@synthesize managedObjectContext = _managedObjectContext;

- (BOOL)importFileAtPath:(NSString *)filePath attributes:(NSMutableDictionary *)spotlightData error:(NSError **)error
{
        
    NSDictionary *pathInfo = [NSPersistentStoreCoordinator elementsDerivedFromExternalRecordURL:[NSURL fileURLWithPath:filePath]];
            
    self.modelURL = [NSURL fileURLWithPath:[pathInfo valueForKey:NSModelPathKey]];
    self.storeURL = [NSURL fileURLWithPath:[pathInfo valueForKey:NSStorePathKey]];


    NSURL *objectURI = [pathInfo valueForKey:NSObjectURIKey];
    NSManagedObjectID *oid = [[self persistentStoreCoordinator] managedObjectIDForURIRepresentation:objectURI];

    if (!oid) {
        NSLog(@"%@:%@ to find object id from path %@", [self class], NSStringFromSelector(_cmd), filePath);
        return NO;
    }

    NSManagedObject *instance = [[self managedObjectContext] objectWithID:oid];

    // how you process each instance will depend on the entity that the instance belongs to

    if ([[[instance entity] name] isEqualToString:@"YOUR_ENTITY_NAME"]) {

        // set the display name for Spotlight search result

        NSString *yourDisplayString =  [NSString stringWithFormat:@"YOUR_DISPLAY_STRING %@", [instance valueForKey:@"SOME_KEY"]];
        spotlightData[(NSString *)kMDItemDisplayName] = yourDisplayString;
        
         /*
            Determine how you want to store the instance information in 'spotlightData' dictionary.
            For each property, pick the key kMDItem... from MDItem.h that best fits its content.  
            If appropriate, aggregate the values of multiple properties before setting them in the dictionary.
            For relationships, you may want to flatten values. 

            id YOUR_FIELD_VALUE = [instance valueForKey:ATTRIBUTE_NAME];
            spotlightData[(NSString *) kMDItem...] = YOUR_FIELD_VALUE;
            ... more property values;
            To determine if a property should be indexed, call isIndexedBySpotlight
         */
    }

    return YES;
}

static NSURL				*cachedModelURL = nil;
static NSManagedObjectModel *cachedModel = nil;
static NSDate				*cachedModelModificationDate =nil;

// Returns the managed object model. The last read model is cached in a global variable and reused if the URL and modification date are identical
- (NSManagedObjectModel *)managedObjectModel
{
    if (_managedObjectModel != nil)
        return _managedObjectModel;
	
	NSDictionary *modelFileAttributes = [[NSFileManager defaultManager] attributesOfItemAtPath:[self.modelURL path] error:nil];
	NSDate *modelModificationDate =  modelFileAttributes[NSFileModificationDate];
	
	if ([cachedModelURL isEqual:self.modelURL] && [modelModificationDate isEqualToDate:cachedModelModificationDate]) {
		_managedObjectModel = cachedModel;
	} 	
	
	if (!_managedObjectModel) {
		_managedObjectModel = [[NSManagedObjectModel alloc] initWithContentsOfURL:self.modelURL];

		if (!_managedObjectModel) {
			NSLog(@"%@:%@ unable to load model at URL %@", [self class], NSStringFromSelector(_cmd), self.modelURL);
			return nil;
		}

		// Clear out all custom classes used by the model to avoid having to link them
		// with the importer. Remove this code if you need to access your custom logic.
		NSString *managedObjectClassName = [NSManagedObject className];
		for (NSEntityDescription *entity in _managedObjectModel) {
			[entity setManagedObjectClassName:managedObjectClassName];
		}
		
		// cache last loaded model

		cachedModelURL = self.modelURL;
		cachedModel = _managedObjectModel;
		cachedModelModificationDate = modelModificationDate;
	}
	
	return _managedObjectModel;
}

// Returns the persistent store coordinator for the importer.  
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator
{
    if (_persistentStoreCoordinator)
        return _persistentStoreCoordinator;

    NSError *error = nil;
        
    _persistentStoreCoordinator = [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:[self managedObjectModel]];
    if (![_persistentStoreCoordinator addPersistentStoreWithType:YOUR_STORE_TYPE configuration:nil URL:self.storeURL options:nil error:&error]) {
        NSLog(@"%@:%@ unable to add persistent store coordinator - %@", [self class], NSStringFromSelector(_cmd), error);
    }    

    return _persistentStoreCoordinator;
}

// Returns the managed object context for the importer; already bound to the persistent store coordinator. 
- (NSManagedObjectContext *)managedObjectContext
{
    if (_managedObjectContext)
        return _managedObjectContext;

    NSPersistentStoreCoordinator *coordinator = [self persistentStoreCoordinator];
	if (!coordinator) {
        NSLog(@"%@:%@ unable to get persistent store coordinator", [self class], NSStringFromSelector(_cmd));
		return nil;
	}

	_managedObjectContext = [[NSManagedObjectContext alloc] init];
	[_managedObjectContext setPersistentStoreCoordinator:coordinator];
    
    return _managedObjectContext;
}

@end
