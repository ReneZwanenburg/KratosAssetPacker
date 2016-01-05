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

alias Hash = ubyte[digestLength!MD5];

struct FileInfo
{
	Hash	hash;
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
		uint numAssets = inputFiles.count().to!uint;
		outputFile.rawWrite([numAssets]);

		ulong currentWriteOffset = numAssets.sizeof + numAssets * FileInfo.sizeof;
		ulong currentOffset = alignOffset(currentWriteOffset);

		foreach(inputFile; inputFiles)
		{
			auto nextOffset = currentOffset + inputFile.size;
			auto path = relativePath(inputFile.name, inputDirectory).replace("\\", "/");
			auto info = FileInfo(getAssetHash(inputDirectory, inputFile), currentOffset, nextOffset);

			writefln("%(%.2X%), offset: %.10d, size: %.10d -> %s", info.hash[], currentOffset, inputFile.size, path);

			outputFile.rawWrite([info]);
			currentOffset = alignOffset(nextOffset);
		}

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

	if(numAssets != inputFiles.count()) return true;
	if(inputFiles.any!(a => a.timeLastModified > outputFileName.timeLastModified)) return true;

	int[Hash] assetMap;
	foreach(existingAsset; assetDescriptions)
	{
		assetMap[existingAsset.hash] = 0;
	}

	foreach(inputFile; inputFiles)
	{
		auto hash = getAssetHash(inputDirectory, inputFile);
		auto entry = hash in assetMap;

		if(entry is null) return true;
		else assetMap.remove(hash);
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

Hash getAssetHash(DirEntry assetDirectory, DirEntry asset)
{
	return md5Of(relativePath(asset, assetDirectory).replace("\\", "/"));
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