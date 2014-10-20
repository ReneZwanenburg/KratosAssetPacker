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

	auto inputDirectories = jobFile["input"].deserializeJson!(string[]).map!absolutePath;
	auto outputDirectory = jobFile["output"].get!string.absolutePath;

	assert(inputDirectories.all!isDir);
	assert(outputDirectory.isDir);

	foreach(inputDirectory; inputDirectories.map!DirEntry)
	{
		auto outputFileName = buildPath(outputDirectory, inputDirectory.dirName.baseName ~ ".assetpack");

		if(!needsUpdate(outputFileName, inputDirectory))
		{
			writeln("Asset pack ", outputFileName, " up to date");
			continue;
		}

		writeln("Updating Asset pack ", outputFileName);

		auto outputFile = File(outputFileName, "w");
		auto inputFiles = inputDirectory.getInputFiles();
		uint numAssets = inputFiles.count().to!uint;
		outputFile.rawWrite([numAssets]);

		ulong currentOffset = alignOffset(numAssets.sizeof + numAssets * FileInfo.sizeof);

		foreach(inputFile; inputFiles)
		{
			auto nextOffset = currentOffset + inputFile.size;
			auto path = relativePath(inputFile.name, inputDirectory).replace("\\", "/");
			auto info = FileInfo(getAssetHash(inputDirectory, inputFile), currentOffset, currentOffset + inputFile.size);

			writefln("%(%.2X%), offset: %.10d, size: %.10d -> %s", info.hash[], currentOffset, inputFile.size, path);

			outputFile.rawWrite([info]);
			currentOffset = alignOffset(currentOffset + inputFile.size);
		}

		writeln("Copying assets to pack...");
		
		foreach(asset; inputFiles)
		{
			foreach(_; 0..requiredPadding(outputFile.tell))
			{
				outputFile.rawWrite([cast(ubyte)0]);
			}

			foreach(chunk; File(asset.name).byChunk(128 * 1024))
			{
				outputFile.rawWrite(chunk);
			}
		}

		writeln(outputFileName, " update successful");
	}
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

Hash getAssetHash(DirEntry assetDirectory, DirEntry asset)
{
	return md5Of(relativePath(asset, assetDirectory).replace("\\", "/"));
}

auto getInputFiles(string directory)
{
	return directory.dirEntries(SpanMode.depth).filter!(a => a.isFile).array;
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