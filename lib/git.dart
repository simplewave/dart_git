import 'dart:io';

import 'package:file/file.dart';
import 'package:file/local.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import 'package:dart_git/config.dart';
import 'package:dart_git/exceptions.dart';
import 'package:dart_git/git_hash.dart';
import 'package:dart_git/git_remote.dart';
import 'package:dart_git/plumbing/index.dart';
import 'package:dart_git/plumbing/objects/blob.dart';
import 'package:dart_git/plumbing/objects/commit.dart';
import 'package:dart_git/plumbing/objects/object.dart';
import 'package:dart_git/plumbing/objects/tree.dart';
import 'package:dart_git/plumbing/reference.dart';
import 'package:dart_git/storage/object_storage.dart';
import 'package:dart_git/storage/reference_storage.dart';

class GitRepository {
  String workTree;
  String gitDir;

  Config config;

  FileSystem fs;
  ReferenceStorage refStorage;
  ObjectStorage objStorage;

  GitRepository._internal({@required String rootDir, @required this.fs}) {
    workTree = rootDir;
    gitDir = p.join(workTree, '.git');
  }

  static String findRootDir(String path, {FileSystem fs}) {
    fs ??= const LocalFileSystem();

    while (true) {
      var gitDir = p.join(path, '.git');
      if (fs.isDirectorySync(gitDir)) {
        return path;
      }

      if (path == p.separator) {
        break;
      }

      path = p.dirname(path);
    }
    return null;
  }

  static Future<GitRepository> load(String gitRootDir, {FileSystem fs}) async {
    fs ??= const LocalFileSystem();

    var repo = GitRepository._internal(rootDir: gitRootDir, fs: fs);

    var isDir = await fs.isDirectory(gitRootDir);
    if (!isDir) {
      throw InvalidRepoException(gitRootDir);
    }

    var dotGitExists = await fs.isDirectory(repo.gitDir);
    if (!dotGitExists) {
      throw InvalidRepoException(gitRootDir);
    }

    var configPath = p.join(repo.gitDir, 'config');
    var configFileContents = await fs.file(configPath).readAsString();
    repo.config = Config(configFileContents);

    repo.objStorage = ObjectStorage(repo.gitDir, fs);
    repo.refStorage = ReferenceStorage(repo.gitDir, fs);

    return repo;
  }

  static Future<void> init(String path, {FileSystem fs}) async {
    fs ??= const LocalFileSystem();

    // FIXME: Check if path has stuff and accordingly return

    var gitDir = p.join(path, '.git');
    var dirsToCreate = [
      'branches',
      'objects/pack',
      'refs/heads',
      'refs/tags',
    ];
    for (var dir in dirsToCreate) {
      await fs.directory(p.join(gitDir, dir)).create(recursive: true);
    }

    await fs.file(p.join(gitDir, 'description')).writeAsString(
        "Unnamed repository; edit this file 'description' to name the repository.\n");
    await fs
        .file(p.join(gitDir, 'HEAD'))
        .writeAsString('ref: refs/heads/master\n');

    var config = Config('');
    var core = config.section('core');
    core.options['repositoryformatversion'] = '0';
    core.options['filemode'] = 'false';
    core.options['bare'] = 'false';

    await fs.file(p.join(gitDir, 'config')).writeAsString(config.serialize());
  }

  Future<void> saveConfig() {
    return fs.file(p.join(gitDir, 'config')).writeAsString(config.serialize());
  }

  Future<List<String>> branches() async {
    var refs = await refStorage.listReferences(refHeadPrefix);
    return refs.map((r) => r.branchName()).toList();
  }

  Future<String> currentBranch() async {
    var _head = await head();
    if (_head.isHash) {
      return null;
    }

    return _head.target.branchName();
  }

  Future<BranchConfig> setUpstreamTo(
      GitRemote remote, String remoteBranchName) async {
    var branchName = await currentBranch();
    var brConfig = await config.branch(branchName);
    if (brConfig == null) {
      brConfig = BranchConfig();
      brConfig.name = branchName;

      config.branches[branchName] = brConfig;
    }
    brConfig.remote = remote.name;
    brConfig.merge = ReferenceName.head(remoteBranchName);

    await saveConfig();
    return brConfig;
  }

  Future<GitHash> createBranch(String name) async {
    var headRef = await resolveReference(await head());
    var branch = ReferenceName.head(name);

    await refStorage.saveRef(Reference.hash(branch, headRef.hash));
    return headRef.hash;
  }

  List<GitRemote> remotes() {
    return config.remotes;
  }

  Future<GitRemote> addRemote(String name, String url) async {
    var existingRemote = config.remotes.firstWhere(
      (r) => r.name == name,
      orElse: () => null,
    );
    if (existingRemote != null) {
      throw Exception('fatal: remote "$name" already exists.');
    }

    var remote = GitRemote();
    remote.name = name;
    remote.url = url;
    remote.fetch = '+refs/heads/*:refs/remotes/$name/*';

    config.remotes.add(remote);
    await saveConfig();

    return remote;
  }

  GitRemote remote(String name) {
    return config.remotes.firstWhere((r) => r.name == name, orElse: () => null);
  }

  Future<Reference> head() async {
    return refStorage.reference(ReferenceName('HEAD'));
  }

  Future<Reference> resolveReference(Reference ref) async {
    if (ref.type == ReferenceType.Hash) {
      return ref;
    }

    var resolvedRef = await refStorage.reference(ref.target);
    if (resolvedRef == null) {
      return null;
    }
    return resolveReference(resolvedRef);
  }

  Future<Reference> resolveReferenceName(ReferenceName refName) async {
    var resolvedRef = await refStorage.reference(refName);
    if (resolvedRef == null) {
      print('resolveReferenceName($refName) failed');
      return null;
    }
    return resolveReference(resolvedRef);
  }

  Future<bool> canPush() async {
    var head = await this.head();
    if (head.isHash) {
      return false;
    }

    var brConfig = await config.branch(head.target.branchName());
    if (brConfig == null) {
      // FIXME: Maybe we can push other branches!
      return false;
    }

    // Construct remote's branch
    var remoteBranchName = brConfig.merge.branchName();
    var remoteRef = ReferenceName.remote(brConfig.remote, remoteBranchName);

    var headHash = (await resolveReference(head)).hash;
    var remoteHash = (await resolveReferenceName(remoteRef)).hash;
    return headHash != remoteHash;
  }

  Future<int> countTillAncestor(GitHash from, GitHash ancestor) async {
    var seen = <GitHash>{};
    var parents = <GitHash>[];
    parents.add(from);
    while (parents.isNotEmpty) {
      var sha = parents[0];
      if (sha == ancestor) {
        break;
      }
      parents.removeAt(0);
      seen.add(sha);

      GitObject obj;
      try {
        obj = await objStorage.readObjectFromHash(sha);
      } catch (e) {
        print(e);
        return -1;
      }
      assert(obj is GitCommit);
      var commit = obj as GitCommit;

      for (var p in commit.parents) {
        if (seen.contains(p)) continue;
        parents.add(p);
      }
    }

    return parents.isEmpty ? -1 : seen.length;
  }

  Future<GitIndex> readIndex() async {
    var file = fs.file(p.join(gitDir, 'index'));
    if (!file.existsSync()) {
      return GitIndex(versionNo: 2);
    }

    return GitIndex.decode(await file.readAsBytes());
  }

  Future<void> writeIndex(GitIndex index) async {
    var path = p.join(gitDir, 'index.new');
    var file = fs.file(path);
    await file.writeAsBytes(index.serialize());
    await file.rename(p.join(gitDir, 'index'));
  }

  Future<int> numChangesToPush() async {
    var head = await this.head();
    if (head.isHash) {
      return 0;
    }

    var brConfig = await config.branch(head.target.branchName());
    if (brConfig == null) {
      return 0;
    }

    // Construct remote's branch
    var remoteBranchName = brConfig.merge.branchName();
    var remoteRef = ReferenceName.remote(brConfig.remote, remoteBranchName);

    var headHash = (await resolveReference(head)).hash;
    var remoteHash = (await resolveReferenceName(remoteRef)).hash;

    if (headHash == null || remoteHash == null) {
      return 0;
    }
    if (headHash == remoteHash) {
      return 0;
    }

    var aheadBy = await countTillAncestor(headHash, remoteHash);
    return aheadBy != -1 ? aheadBy : 0;
  }

  Future<void> addFileToIndex(GitIndex index, String filePath) async {
    var file = fs.file(filePath);
    if (!file.existsSync()) {
      throw Exception("fatal: pathspec '$filePath' did not match any files");
    }

    // Save that file as a blob
    var data = await file.readAsBytes();
    var blob = GitBlob(data, null);
    var hash = await objStorage.writeObject(blob);

    var pathSpec = filePath;
    if (pathSpec.startsWith(workTree)) {
      pathSpec = filePath.substring(workTree.length + 1);
    }

    // Add it to the index
    GitIndexEntry entry;
    for (var e in index.entries) {
      if (e.path == pathSpec) {
        entry = e;
        break;
      }
    }

    var stat = await FileStat.stat(filePath);

    // Existing file
    if (entry != null) {
      entry.hash = hash;
      entry.fileSize = data.length;

      entry.cTime = stat.changed;
      entry.mTime = stat.modified;
      return;
    }

    // New file
    entry = GitIndexEntry.fromFS(pathSpec, stat, hash);
    index.entries.add(entry);
  }

  Future<void> addDirectoryToIndex(GitIndex index, String dirPath,
      {bool recursive = false}) async {
    if (!dirPath.startsWith(workTree)) {
      return;
    }
    var dir = fs.directory(dirPath);
    await for (var fsEntity
        in dir.list(recursive: recursive, followLinks: false)) {
      if (fsEntity.path.startsWith(gitDir)) {
        continue;
      }
      var stat = await fsEntity.stat();
      if (stat.type != FileSystemEntityType.file) {
        continue;
      }

      print(fsEntity.path);
      await addFileToIndex(index, fsEntity.path);
    }
  }

  Future<void> rmFileFromIndex(GitIndex index, String filePath) async {
    var pathSpec = filePath;
    if (pathSpec.startsWith(workTree)) {
      pathSpec = pathSpec.substring(workTree.length);
      if (pathSpec.startsWith('/')) {
        pathSpec = pathSpec.substring(1);
      }
    }
    index.entries = index.entries.where((e) => e.path != pathSpec).toList();

    // FIXME: What if nothing matches
  }

  Future<GitCommit> commit({
    @required String message,
    @required GitAuthor author,
    GitAuthor committer,
    bool addAll = false,
  }) async {
    committer ??= author;

    var index = await readIndex();

    if (addAll) {
      await addDirectoryToIndex(index, workTree, recursive: true);
      await writeIndex(index);
    }

    var treeHash = await writeTree(index);
    var parents = <GitHash>[];

    var headRef = await head();
    if (headRef != null) {
      var parentRef = await resolveReference(headRef);
      if (parentRef != null) {
        parents.add(parentRef.hash);
      }
    }

    var commit = GitCommit.create(
      author: author,
      committer: committer,
      parents: parents,
      message: message,
      treeHash: treeHash,
    );
    var hash = await objStorage.writeObject(commit);

    // Update the ref of the current branch
    var branchName = await currentBranch();
    if (branchName == null) {
      var h = await head();
      assert(h.target.isBranch());
      branchName = h.target.branchName();
    }

    var newRef = Reference.hash(ReferenceName.head(branchName), hash);

    await refStorage.saveRef(newRef);

    return commit;
  }

  Future<GitHash> writeTree(GitIndex index) async {
    var allTreeDirs = {''};
    var treeObjects = {'': GitTree.empty()};
    var treeObjFullPath = <GitTree, String>{};

    index.entries.forEach((entry) {
      var fullPath = entry.path;
      var fileName = p.basename(fullPath);
      var dirName = p.dirname(fullPath);

      // Construct all the tree objects
      var allDirs = <String>[];
      while (dirName != '.') {
        allTreeDirs.add(dirName);
        allDirs.add(dirName);

        dirName = p.dirname(dirName);
      }

      allDirs.sort(dirSortFunc);

      for (var dir in allDirs) {
        if (!treeObjects.containsKey(dir)) {
          var tree = GitTree.empty();
          treeObjects[dir] = tree;
        }

        var parentDir = p.dirname(dir);
        if (parentDir == '.') parentDir = '';

        var parentTree = treeObjects[parentDir];
        var folderName = p.basename(dir);
        treeObjFullPath[parentTree] = parentDir;

        var i = parentTree.leaves.indexWhere((e) => e.path == folderName);
        if (i != -1) {
          continue;
        }
        parentTree.leaves.add(GitTreeLeaf(
          mode: GitFileMode.Dir,
          path: folderName,
          hash: null,
        ));
      }

      dirName = p.dirname(fullPath);
      if (dirName == '.') {
        dirName = '';
      }

      var leaf = GitTreeLeaf(
        mode: entry.mode,
        path: fileName,
        hash: entry.hash,
      );
      treeObjects[dirName].leaves.add(leaf);
    });
    assert(treeObjects.containsKey(''));

    // Write all the tree objects
    var hashMap = <String, GitHash>{};

    var allDirs = allTreeDirs.toList();
    allDirs.sort(dirSortFunc);

    for (var dir in allDirs.reversed) {
      var tree = treeObjects[dir];
      assert(tree != null);

      for (var i = 0; i < tree.leaves.length; i++) {
        var leaf = tree.leaves[i];

        if (leaf.hash != null) {
          assert(await () async {
            var leafObj = await objStorage.readObjectFromHash(leaf.hash);
            return leafObj.formatStr() == 'blob';
          }());
          continue;
        }

        var fullPath = p.join(treeObjFullPath[tree], leaf.path);
        var hash = hashMap[fullPath];
        assert(hash != null);

        tree.leaves[i] = GitTreeLeaf(
          mode: leaf.mode,
          path: leaf.path,
          hash: hash,
        );
      }

      for (var leaf in tree.leaves) {
        assert(leaf.hash != null);
      }

      var hash = await objStorage.writeObject(tree);
      hashMap[dir] = hash;
    }

    return hashMap[''];
  }
}

// Sort allDirs on bfs
@visibleForTesting
int dirSortFunc(String a, String b) {
  var aCnt = '/'.allMatches(a).length;
  var bCnt = '/'.allMatches(b).length;
  if (aCnt != bCnt) {
    if (aCnt < bCnt) return -1;
    if (aCnt > bCnt) return 1;
  }
  if (a.isEmpty && b.isEmpty) return 0;
  if (a.isEmpty) {
    return -1;
  }
  if (b.isEmpty) {
    return 1;
  }
  return a.compareTo(b);
}
