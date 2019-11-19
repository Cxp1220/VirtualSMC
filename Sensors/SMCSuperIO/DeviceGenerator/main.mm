//
//  main.mm
//  DeviceGenerator
//
//  Copyright © 2016-2017 vit9696. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <Cocoa/Cocoa.h>

#define SYSLOG(str, ...) printf("DeviceGenerator: " str "\n", ## __VA_ARGS__)
#define ERROR(str, ...) do { SYSLOG(str, ## __VA_ARGS__); exit(1); } while(0)

NSString *ResourceHeader {@"\
//                                                   \n\
//  Devices.cpp                                      \n\
//  SMCSuperIO                                       \n\
//                                                   \n\
//  Copyright © 2016-2019 joedm. All rights reserved.\n\
//                                                   \n\
//  This is an autogenerated file!                   \n\
//  Please avoid any modifications!                  \n\
//                                                   \n\n\
#include \"Devices.hpp\"\n\
#include \"NuvotonDevice.hpp\"\n\
#include \"FintekDevice.hpp\"\n\
#include \"ITEDevice.hpp\"\n\
#include \"WinbondDevice.hpp\"\n\n"
};

static void appendFile(NSString *file, NSString *data) {
	NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:file];
	[handle seekToEndOfFile];
	[handle writeData:[data dataUsingEncoding:NSUTF8StringEncoding]];
	[handle closeFile];
}

// FIXME: use shared includes for this
static constexpr uint8_t WinbondHardwareMonitorLDN = 0x0B;
static constexpr uint8_t FintekITEHardwareMonitorLDN = 0x04;

static NSString *generateSensor(NSArray *sensors, NSString *sensorReading, NSString *sensorKind, NSString *valueType) {
	if (!sensors) {
		return @"";
	}
	NSString *capitalizedSensorKind = [sensorKind capitalizedString];
	NSMutableString *sensorsContents = [NSMutableString stringWithCapacity: 1024];
	[sensorsContents appendString:@"public:\n"];
	// uint8_t getTachometerCount()
	[sensorsContents appendFormat: @"\tuint8_t get%@Count() override {\n\t\treturn %lu;\n\t}\n\n", capitalizedSensorKind, [sensors count]];

	// uint16_t updateTachometer(uint8_t index)
	if (!sensorReading) {
		sensorReading = [NSString stringWithFormat:@"%@Read", sensorKind];
	}
	[sensorsContents appendFormat: @"\t%@ update%@(uint8_t index) override {\n\t\treturn %@(index);\n\t}\n\n", valueType, capitalizedSensorKind, sensorReading];

	// const char* getTachometerName(uint8_t index);
	[sensorsContents appendFormat: @"\tconst char* get%@Name(uint8_t index) override {\n\t\tif (index < get%@Count()) {\n\t\t\treturn %@Names[index];\n\t\t}\n\t\treturn nullptr;\n\t}\n\n", capitalizedSensorKind, capitalizedSensorKind, sensorKind];

	uint32_t index = 0;
	NSMutableString *sensorNames = [NSMutableString stringWithFormat:@"private:\n\tconst char* %@Names[%lu] = {\n", sensorKind, [sensors count]];
	for (NSDictionary *sensor in sensors) {
		NSString *sensorName = [sensor objectForKey: @"Name"];
		if (sensorName) {
			[sensorNames appendFormat:@"\t\t\"%@\",\n", sensorName];
			index++;
		}
	}
	if ([sensors count] == index) {
		[sensorNames appendString: @"\t};\n"];
		[sensorsContents appendString: sensorNames];
	} else {
		SYSLOG("Not all names for tachometers provided in the descriptor.");
	}
	
	return sensorsContents;
}

static NSString *processDevice(NSDictionary *deviceDict, NSMutableString *factoryMethodContents, uint32_t index) {
	NSString *deviceClassName = [deviceDict objectForKey:@"BaseClassName"];
	if (!deviceClassName) {
		// class name collision will be verified by CXX compiler
		SYSLOG("No BaseClassName key specified, skipping the descriptor.");
		return @"";
	}
	NSString *deviceNamespace = nil;
	uint8_t defaultLdn = 0xFF;
	if ([deviceClassName hasPrefix: @"Nuvoton"]) {
		// Nuvoton
		deviceNamespace = @"Nuvoton";
		defaultLdn = WinbondHardwareMonitorLDN;
	} else if ([deviceClassName hasPrefix: @"Winbond"]) {
		// Winbond
		deviceNamespace = @"Winbond";
		defaultLdn = WinbondHardwareMonitorLDN;
	} else if ([deviceClassName hasPrefix: @"Fintek"]) {
		// Fintek
		deviceNamespace = @"Fintek";
		defaultLdn = FintekITEHardwareMonitorLDN;
	} else if ([deviceClassName hasPrefix: @"ITE"]) {
		// ITE
		deviceNamespace = @"ITE";
		defaultLdn = FintekITEHardwareMonitorLDN;
	} else {
		SYSLOG("Unknown BaseClassName specified: %s, skipping the descriptor.", [deviceNamespace UTF8String]);
		return @"";
	}
	NSString *deviceGeneratedClassName = [NSString stringWithFormat: @"Generated%@Device_%d", deviceNamespace, index];
	NSString *baseClassName = [NSString stringWithFormat:@"%@::%@", deviceNamespace, deviceClassName];

	NSArray *compatibleDevices = [deviceDict objectForKey:@"CompatibleDevices"];
	if (!compatibleDevices) {
		SYSLOG("No CompatibleDevices key specified, skipping the descriptor.");
		return @"";
	}
	NSMutableString *fileContents = [NSMutableString stringWithCapacity: 16384];
	
	auto baseClassContents = [NSMutableString stringWithFormat:@"class %@ : public %@ {\n", deviceGeneratedClassName, baseClassName];

	// void onPowerOn()
	NSString *onPowerOn = [deviceDict objectForKey:@"onPowerOn"];
	if (onPowerOn) {
		[baseClassContents appendFormat: @"\tvoid onPowerOn() override {\n\t\t%@();\n\t}\n\n", onPowerOn];
	}

	// proceed with sensors
	NSDictionary *sensors = [deviceDict objectForKey:@"Sensors"];
	if (!sensors) {
		SYSLOG("No Sensors key specified, skipping the descriptor.");
		return @"";
	}
	// tachometers
	[baseClassContents appendString: generateSensor([sensors objectForKey:@"Tachometer"], [sensors objectForKey:@"TachometerReading"], @"tachometer", @"uint16_t")];
	// voltages
	[baseClassContents appendString: generateSensor([sensors objectForKey:@"Voltage"], [sensors objectForKey:@"VoltageReading"], @"voltage", @"float")];
	[baseClassContents appendString: @"\n};\n\n"];

	for (NSDictionary *compDevice in compatibleDevices) {
		NSNumber *deviceID = [compDevice objectForKey: @"DeviceID"];
		if (!deviceID) {
			SYSLOG("No DeviceID key specified for the compatible device, skipping this entry.");
			continue;
		}
		auto classContents = [NSMutableString stringWithFormat:@"class Device_0x%04X final : public %@ {\npublic:\n", [deviceID intValue], deviceGeneratedClassName];
		// factory method
		NSNumber *deviceIdMask = [compDevice objectForKey: @"DeviceIDMask"];
		NSString *deviceIdTest;
		if (deviceIdMask) {
			deviceIdTest = [NSString stringWithFormat: @"(deviceId & 0x%04X)", [deviceIdMask intValue]];
		} else {
			deviceIdTest = @"deviceId";
		}
		[classContents appendFormat: @"\tstatic SuperIODevice *createDevice(uint16_t deviceId) {\n\t\tif (%@ == 0x%04X)\n\t\t\treturn new Device_0x%04X();\n\t\treturn nullptr;\n\t}\n\n", deviceIdTest, [deviceID intValue], [deviceID intValue]];
		// uint8_t getLdn()
		NSNumber *ldn = [compDevice objectForKey: @"LDN"]; // optional key
		[classContents appendFormat: @"\tuint8_t getLdn() override {\n\t\treturn 0x%02X;\n\t}\n\n", ldn ? [ldn intValue] : defaultLdn];
		// const char* getModelName()
		NSString *displayName = [compDevice objectForKey: @"DisplayName"];
		if (!displayName) {
			displayName = @"<Unspecified>";
		}
		[classContents appendFormat: @"\tconst char* getModelName() override {\n\t\treturn \"%@\";\n\t}\n\n", displayName];
		[factoryMethodContents appendFormat: @"\tdevice = Device_0x%04X::createDevice(deviceId);\n\tif (device) return device;\n", [deviceID intValue]];
		[classContents appendString: @"};\n\n"];
		[baseClassContents appendString: classContents];
	}
	[fileContents appendString: baseClassContents];

	return fileContents;
}

int main(int argc, const char * argv[]) {
	if (argc != 3) {
		ERROR("Usage:\n\t\t%s DeviceDescriptorsDir OutputCXXSourceFile\n", argv[0]);
	}
	auto basePath = [[NSString alloc] initWithUTF8String:argv[1]];
	auto outputCpp = [[NSString alloc] initWithUTF8String:argv[2]];

	NSFileManager *fileManager = [NSFileManager defaultManager];

	NSDirectoryEnumerator *dirEnum = [fileManager enumeratorAtPath:basePath];
	NSMutableArray *files = [[NSMutableArray alloc]init];
	NSString *file;
	while ((file = [dirEnum nextObject])) {
		if ([[file pathExtension] isEqualToString: @"plist"]) {
			NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:[basePath stringByAppendingPathComponent:file]];
			if (!dict) {
				SYSLOG("Can't read file %s.", [file UTF8String]);
				continue;
			}
			[files addObject:dict];
		}
	}

	if (![files count]) {
		ERROR("No device descriptors found.");
	}
	
	// Create a file
	[fileManager createFileAtPath:outputCpp contents:nil attributes:nil];
	appendFile(outputCpp, ResourceHeader);
	// Device factory
	NSMutableString *factoryMethodContents = [NSMutableString stringWithString: @"SuperIODevice *createDevice(uint16_t deviceId) {\n\tSuperIODevice *device;\n"];
	uint32_t i = 0;
	for (NSDictionary *deviceDict in files) {
		auto fileContents = processDevice(deviceDict, factoryMethodContents, i++);
		appendFile(outputCpp, fileContents);
	}
	[factoryMethodContents appendString: @"\treturn nullptr;\n}"];
	appendFile(outputCpp, factoryMethodContents);
}
