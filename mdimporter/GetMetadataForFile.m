//
//  GetMetadataForFile.m
//  Video
//
//  Created by Jonathan Harris on 03/07/2014.
//
//

#include <CoreFoundation/CoreFoundation.h>
#import <CoreData/CoreData.h>

#import <VLCKit/VLCLibrary.h>
#import <VLCKit/VLCMedia.h>

NSString* int2fourcc(FourCharCode aCode)
{
#if TARGET_RT_LITTLE_ENDIAN
    char fourChar[5] = {*(((char*)&aCode)), *(((char*)&aCode)+1), *(((char*)&aCode)+2), *(((char*)&aCode)+3), 0};
#else
    char fourChar[5] = {*(((char*)&aCode)+3), *(((char*)&aCode)+2), *(((char*)&aCode)+1), *(((char*)&aCode)), 0};
#endif
    NSString *fourcc = [NSString stringWithCString:fourChar encoding:NSUTF8StringEncoding];
    return fourcc;
}

//==============================================================================
//
//	Get metadata attributes from document files
//
//	The purpose of this function is to extract useful information from the
//	file formats for your document, and set the values into the attribute
//  dictionary for Spotlight to include.
//
//==============================================================================

Boolean GetMetadataForFile(void *thisInterface, CFMutableDictionaryRef attributes, CFStringRef contentTypeUTI, CFStringRef pathToFile)
{
    // Pull any available metadata from the file at the specified path
    // Return the attribute keys and attribute values in the dict
    // Return TRUE if successful, FALSE if there was no data provided
	// The path could point to either a Core Data store file in which
	// case we import the store's metadata, or it could point to a Core
	// Data external record file for a specific record instances

    @autoreleasepool
    {
        VLCMedia *media = [VLCMedia mediaWithPath:(__bridge NSString *)(pathToFile)];
        if (!media) return false;
        
        NSArray *tracksinfo = [media tracksInformation];
        if (![tracksinfo count]) return false;

        // Stuff we collect along the way
        CFMutableArrayRef codecs     = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        CFMutableArrayRef mediatypes = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        CFMutableArrayRef languages  = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
        
        NSString *thing = nil;
        if ((thing = [media metadataForKey:VLCMetaInformationTitle]) && [thing length] &&
            !CFStringHasSuffix(pathToFile, (__bridge CFStringRef) thing))   // In the absence of a Title VLC defaults to the file's basename
            CFDictionaryAddValue(attributes, kMDItemTitle, (__bridge const void *) thing);
        if ((thing = [media metadataForKey:VLCMetaInformationArtist]) && [thing length])
            CFDictionaryAddValue(attributes, kMDItemAuthors, (__bridge const void *) thing);
        if ((thing = [media metadataForKey:VLCMetaInformationGenre]) && [thing length])
            CFDictionaryAddValue(attributes, kMDItemGenre, (__bridge const void *) thing);
        if ((thing = [media metadataForKey:VLCMetaInformationCopyright]) && [thing length])
            CFDictionaryAddValue(attributes, kMDItemCopyright, (__bridge const void *) thing);
        if ((thing = [media metadataForKey:VLCMetaInformationDescription]) && [thing length])
            CFDictionaryAddValue(attributes, kMDItemDescription, (__bridge const void *) thing);
        if ((thing = [media metadataForKey:VLCMetaInformationDate]) && [thing length])
            CFDictionaryAddValue(attributes, kMDItemContentCreationDate, (__bridge const void *) thing);
        if ((thing = [media metadataForKey:VLCMetaInformationLanguage]) && [thing length])
            CFArrayAppendValue(languages, (__bridge const void *) thing);
        if ((thing = [media metadataForKey:VLCMetaInformationPublisher]) && [thing length])
        {
            CFTypeRef array[1] = { (__bridge CFTypeRef)(thing) };
            CFDictionaryAddValue(attributes, kMDItemPublishers, CFArrayCreate(kCFAllocatorDefault, array, 1, &kCFTypeArrayCallBacks));
        }
        // crashes
        //if ((thing = [media metadataForKey:VLCMetaInformationEncodedBy]) && [thing length])
        //    CFDictionaryAddValue(attributes, kMDItemAudioEncodingApplication, (__bridge const void *) thing);
        
        VLCTime *length = [media lengthWaitUntilDate:[NSDate dateWithTimeIntervalSinceNow:60]];
        if (length && [[length numberValue] boolValue])
            CFDictionaryAddValue(attributes, kMDItemDurationSeconds,
                                 (__bridge const void *) ([NSNumber numberWithInt:[[length numberValue] intValue]/1000]));
        
        for (NSDictionary *info in tracksinfo)
        {
            if ([[info objectForKey:VLCMediaTracksInformationType] isEqualToString:VLCMediaTracksInformationTypeAudio])
            {
                NSNumber *number;
                if ((number = [info objectForKey:VLCMediaTracksInformationCodec]) && [number boolValue])
                    CFArrayAppendValue(codecs, (__bridge const void *)(int2fourcc([number intValue])));
                if ((number = [info objectForKey:VLCMediaTracksInformationBitrate]) && [number boolValue])
                    CFDictionaryAddValue(attributes, kMDItemAudioBitRate, (__bridge const void *) number);
                if ((thing = [info objectForKey:VLCMediaTracksInformationLanguage]))
                    CFArrayAppendValue(languages, (__bridge const void *) thing);
                if ((number = [info objectForKey:VLCMediaTracksInformationAudioChannelsNumber]) && [number boolValue])
                    CFDictionaryAddValue(attributes, kMDItemAudioChannelCount, (__bridge const void *) number);
                if ((number = [info objectForKey:VLCMediaTracksInformationAudioRate]) && [number boolValue])
                    CFDictionaryAddValue(attributes, kMDItemAudioSampleRate, (__bridge const void *) number);
                
                CFArrayAppendValue(mediatypes, CFSTR("Sound"));
            }
            else if ([[info objectForKey:VLCMediaTracksInformationType] isEqualToString:VLCMediaTracksInformationTypeVideo])
            {
                NSNumber *number;
                if ((number = [info objectForKey:VLCMediaTracksInformationCodec]) && [number boolValue])
                    CFArrayAppendValue(codecs, (__bridge const void *)(int2fourcc([number intValue])));
                if ((number = [info objectForKey:VLCMediaTracksInformationBitrate]) && [number boolValue])
                    CFDictionaryAddValue(attributes, kMDItemVideoBitRate, (__bridge const void *) number);
                if ((number = [info objectForKey:VLCMediaTracksInformationVideoHeight]) && [number boolValue])
                    CFDictionaryAddValue(attributes, kMDItemPixelHeight, (__bridge const void *) number);
                if ((number = [info objectForKey:VLCMediaTracksInformationVideoWidth]) && [number boolValue])
                    CFDictionaryAddValue(attributes, kMDItemPixelWidth, (__bridge const void *) number);

                CFArrayAppendValue(mediatypes, CFSTR("Video"));
            }
            else if ([[info objectForKey:VLCMediaTracksInformationType] isEqualToString:VLCMediaTracksInformationTypeText])
            {
                CFArrayAppendValue(mediatypes, CFSTR("Text"));
            }
        }
        
        if (CFArrayGetCount(codecs))
            CFDictionaryAddValue(attributes, kMDItemCodecs, codecs);
		CFRelease(codecs);

        if (CFArrayGetCount(mediatypes))
            CFDictionaryAddValue(attributes, kMDItemMediaTypes, mediatypes);
		CFRelease(mediatypes);

        if (CFArrayGetCount(languages))
            CFDictionaryAddValue(attributes, kMDItemLanguages, languages);
		CFRelease(languages);
    }
    
    return true;    // Return the status
}


