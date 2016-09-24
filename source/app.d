import std.stdio;
import std.exception;
import std.file;
import std.algorithm;
import std.conv;
import std.digest.md;
import std.path;
import std.array;
import std.datetime;
import std.mmfile;
import std.typecons;

import vibe.data.json;

struct FileInfo
{
	ulong	startOffset;
	ulong	endOffset;
}

void main(string[] args)
{
	auto jobFile = readText("AssetPacker.json").parseJsonString();

	auto inputDirectories = jobFile["input"].deserializeJson!(string[]).map!absolutePath.filter!exists.array;
	auto outputDirectory = jobFile["output"].get!string.absolutePath;

	if(!outputDirectory.exists)
	{
		mkdir(outputDirectory);
	}
	
	assert(inputDirectories.all!isDir);
	assert(outputDirectory.isDir);

	foreach(inputDirectory; inputDirectories.map!DirEntry)
	{
		auto outputFileName = buildPath(outputDirectory, getPackfileName(inputDirectory));

		if(!needsUpdate(outputFileName, inputDirectory))
		{
			writeln("Asset pack ", outputFileName, " up to date");
			continue;
		}

		writeln("Updating Asset pack ", outputFileName);

		auto outputFile = File(outputFileName, "wb");
		auto inputFiles = inputDirectory.getInputFiles();
		uint numAssets = inputFiles.count().to!uint + 1; // Add one for filename string table
		outputFile.rawWrite([numAssets]);

		ulong currentWriteOffset = numAssets.sizeof + numAssets * FileInfo.sizeof;
		ulong currentOffset = alignOffset(currentWriteOffset);
		
		string[] nameTable;
		ulong totalNamesLength;

		foreach(inputFile; inputFiles)
		{
			auto nextOffset = currentOffset + inputFile.size;
			auto path = relativePath(inputFile.name, inputDirectory).replace("\\", "/");
			auto info = FileInfo(currentOffset, nextOffset);
			auto name = getAssetName(inputDirectory, inputFile);
			
			writefln("Offset: %.10d, size: %.10d -> %s", currentOffset, inputFile.size, name);

			outputFile.rawWrite([info]);
			currentOffset = alignOffset(nextOffset);
			nameTable ~= name;
			totalNamesLength += name.length;
		}
		
		outputFile.rawWrite([FileInfo(currentOffset, currentOffset + totalNamesLength + (nameTable.length ? nameTable.length - 1 : 0))]);

		writeln("Copying assets to pack...");
		
		foreach(asset; inputFiles)
		{
			auto padBytes = requiredPadding(currentWriteOffset);
			currentWriteOffset += padBytes;
			
			foreach(_; 0..padBytes)
			{
				outputFile.rawWrite([cast(ubyte)0]);
			}

			foreach(chunk; File(asset.name).byChunk(128 * 1024))
			{
				outputFile.rawWrite(chunk);
				currentWriteOffset += chunk.length;
			}
		}
		
		auto padBytes = requiredPadding(currentWriteOffset);
		foreach(_; 0..padBytes) outputFile.rawWrite([cast(ubyte)0]);
		outputFile.rawWrite(nameTable.join('\0'));

		writeln(outputFileName, " update successful");
	}

	writeLoadOrder(outputDirectory, inputDirectories);
}

bool needsUpdate(string outputFileName, DirEntry inputDirectory)
{
	if(!exists(outputFileName)) return true;

	auto outputFile = scoped!MmFile(outputFileName);
	auto numAssets = (cast(uint[])outputFile[0 .. 4])[0];
	auto assetDescriptions = cast(FileInfo[])outputFile[4 .. 4 + numAssets*FileInfo.sizeof];
	auto inputFiles = inputDirectory.getInputFiles();

	 // Subtract one for filename string table
	if(numAssets - 1 != inputFiles.count()) return true;
	if(inputFiles.any!(a => a.timeLastModified > outputFileName.timeLastModified)) return true;

	bool[string] assetMap;
	auto nameTableInfo = assetDescriptions[$-1];
	
	foreach(existingAsset; (cast(string)outputFile[nameTableInfo.startOffset .. nameTableInfo.endOffset]).splitter('\0'))
	{
		assetMap[existingAsset] = true;
	}

	foreach(inputFile; inputFiles)
	{
		auto name = getAssetName(inputDirectory, inputFile);
		auto entry = name in assetMap;

		if(entry is null) return true;
		else assetMap.remove(name);
	}

	return assetMap.length > 0;
}

void writeLoadOrder(string outputDirectory, string[] inputDirs)
{
	auto json = Json.emptyArray;
	json ~= Json("./assets/");
	foreach(inputDir; inputDirs)
	{
		json ~= Json(getPackfileName(inputDir));
	}
	std.file.write(buildPath(outputDirectory, "LoadOrder.json"), json.toPrettyString());
}

string getAssetName(DirEntry assetDirectory, DirEntry asset)
{
	return relativePath(asset, assetDirectory).replace("\\", "/");
}

auto getInputFiles(string directory)
{
	return directory.dirEntries(SpanMode.depth).filter!(a => a.isFile).array;
}

string getPackfileName(string inputDirectory)
{
	return inputDirectory.dirName.baseName ~ ".assetpack";
}

enum Alignment = 16;
ulong alignOffset(ulong position)
{
	return position + requiredPadding(position);
}

ulong requiredPadding(ulong offset)
{
	return (Alignment - (offset % Alignment)) % Alignment;
}