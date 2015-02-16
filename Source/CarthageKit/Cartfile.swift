//
//  Cartfile.swift
//  Carthage
//
//  Created by Justin Spahr-Summers on 2014-10-10.
//  Copyright (c) 2014 Carthage. All rights reserved.
//

import Foundation
import LlamaKit
import Madness
import OGDL
import ReactiveCocoa

/// The relative path to a project's checked out dependencies.
public let CarthageProjectCheckoutsPath = "Carthage/Checkouts"

/// Represents anything that can be parsed from an OGDL node (and its
/// descendants).
private protocol NodeParseable {
	/// Attempts to parse an instance of the receiver from the given node. If
	/// `node` is nil, the receiver should assume a default value (if allowed).
	///
	/// Upon success, returns the parsed value, and the first descendant node
	/// that was not touched.
	class func fromNode(node: Node?) -> Result<(Self, Node?)>
}

/// Represents a Cartfile, which is a specification of a project's dependencies
/// and any other settings Carthage needs to build it.
public struct Cartfile {
	/// The dependencies listed in the Cartfile.
	public var dependencies: [Dependency<VersionSpecifier>]

	public init(dependencies: [Dependency<VersionSpecifier>] = []) {
		self.dependencies = dependencies
	}

	/// Returns the location where Cartfile should exist within the given
	/// directory.
	public static func URLInDirectory(directoryURL: NSURL) -> NSURL {
		return directoryURL.URLByAppendingPathComponent("Cartfile")
	}

	/// Attempts to parse Cartfile information from a string.
	public static func fromString(string: String) -> Result<Cartfile> {
		// TODO: Wrap this in ogdl-swift.
		if let nodes = parse(graph, string) {
			return dependenciesFromNodes(nodes).map { self(dependencies: $0) }
		} else {
			return failure(CarthageError.ParseError(description: "OGDL parse error").error)
		}
	}

	/// Attempts to parse a Cartfile from a file at a given URL.
	public static func fromFile(cartfileURL: NSURL) -> Result<Cartfile> {
		var error: NSError?
		if let cartfileContents = NSString(contentsOfURL: cartfileURL, encoding: NSUTF8StringEncoding, error: &error) {
			return Cartfile.fromString(cartfileContents)
		} else {
			return failure(error ?? CarthageError.ReadFailed(cartfileURL).error)
		}
	}

	/// Appends the contents of another Cartfile to that of the receiver.
	public mutating func appendCartfile(cartfile: Cartfile) {
		dependencies += cartfile.dependencies
	}
}

extension Cartfile: Printable {
	public var description: String {
		return "\(dependencies)"
	}
}

/// Represents a parsed Cartfile.resolved, which specifies which exact version was
/// checked out for each dependency.
public struct ResolvedCartfile {
	/// The dependencies listed in the Cartfile.resolved, in the order that they
	/// should be built.
	public var dependencies: [Dependency<PinnedVersion>]

	public init(dependencies: [Dependency<PinnedVersion>]) {
		self.dependencies = dependencies
	}

	/// Returns the location where Cartfile.resolved should exist within the given
	/// directory.
	public static func URLInDirectory(directoryURL: NSURL) -> NSURL {
		return directoryURL.URLByAppendingPathComponent("Cartfile.resolved")
	}

	/// Attempts to parse Cartfile.resolved information from a string.
	public static func fromString(string: String) -> Result<ResolvedCartfile> {
		// TODO: Wrap this in ogdl-swift.
		if let nodes = parse(graph, string) {
			return dependenciesFromNodes(nodes).map { self(dependencies: $0) }
		} else {
			return failure(CarthageError.ParseError(description: "OGDL parse error").error)
		}
	}
}

extension ResolvedCartfile: Printable {
	public var description: String {
		return dependencies.reduce("") { (string, dependency) in
			return string + "\(dependency)\n"
		}
	}
}

/// Uniquely identifies a project that can be used as a dependency.
public enum ProjectIdentifier: Equatable {
	/// A repository hosted on GitHub.com.
	case GitHub(GitHubRepository)

	/// An arbitrary Git repository.
	case Git(GitURL)

	/// The unique, user-visible name for this project.
	public var name: String {
		switch (self) {
		case let .GitHub(repo):
			return repo.name

		case let .Git(URL):
			return URL.name ?? URL.URLString
		}
	}

	/// The path at which this project will be checked out, relative to the
	/// working directory of the main project.
	public var relativePath: String {
		return CarthageProjectCheckoutsPath.stringByAppendingPathComponent(name)
	}
}

public func ==(lhs: ProjectIdentifier, rhs: ProjectIdentifier) -> Bool {
	switch (lhs, rhs) {
	case let (.GitHub(left), .GitHub(right)):
		return left == right

	case let (.Git(left), .Git(right)):
		return left == right

	default:
		return false
	}
}

extension ProjectIdentifier: Hashable {
	public var hashValue: Int {
		switch (self) {
		case let .GitHub(repo):
			return repo.hashValue

		case let .Git(URL):
			return URL.hashValue
		}
	}
}

extension GitHubRepository: NodeParseable {
	private static func fromNode(node: Node?) -> Result<(GitHubRepository, Node?)> {
		if let node = node {
			return fromNWO(node.value).map { repo in (repo, node.children.first) }
		} else {
			return failure(CarthageError.ParseError(description: "expected GitHub repository name").error)
		}
	}
}

extension GitURL: NodeParseable {
	private static func fromNode(node: Node?) -> Result<(GitURL, Node?)> {
		if let node = node {
			return success(self(node.value), node.children.first)
		} else {
			return failure(CarthageError.ParseError(description: "expected Git repository URL").error)
		}
	}
}

extension ProjectIdentifier: NodeParseable {
	private static func fromNode(node: Node?) -> Result<(ProjectIdentifier, Node?)> {
		switch node?.value {
		case .Some("github"):
			return GitHubRepository.fromNode(node?.children.first).map { repo, remainder in (self.GitHub(repo), remainder) }

		case .Some("git"):
			return GitURL.fromNode(node?.children.first).map { repo, remainder in (self.Git(repo), remainder) }

		case let .Some(other):
			return failure(CarthageError.ParseError(description: "unexpected dependency type \"\(other)\"").error)

		case .None:
			return failure(CarthageError.ParseError(description: "expected dependency type").error)
		}
	}
}

extension ProjectIdentifier: Printable {
	public var description: String {
		switch (self) {
		case let .GitHub(repo):
			return "github \"\(repo)\""

		case let .Git(URL):
			return "git \"\(URL)\""
		}
	}
}

/// Represents a single dependency of a project.
public struct Dependency<V: VersionType>: Equatable {
	/// The project corresponding to this dependency.
	public let project: ProjectIdentifier

	/// The version(s) that are required to satisfy this dependency.
	public var version: V

	public init(project: ProjectIdentifier, version: V) {
		self.project = project
		self.version = version
	}

	/// Maps over the `version` in the receiver.
	public func map<W>(f: V -> W) -> Dependency<W> {
		return Dependency<W>(project: project, version: f(version))
	}
}

public func == <V>(lhs: Dependency<V>, rhs: Dependency<V>) -> Bool {
	return lhs.project == rhs.project && lhs.version == rhs.version
}

/// Parses dependency information from an OGDL subgraph.
private func dependencyFromNode<V: VersionType where V: NodeParseable>(node: Node?) -> Result<(Dependency<V>, Node?)> {
	return ProjectIdentifier.fromNode(node).flatMap { identifier, remainder in
		return V.fromNode(remainder).map { version, remainder in (Dependency<V>(project: identifier, version: version), remainder) }
	}
}

extension Dependency: Printable {
	public var description: String {
		return "\(project) \(version)"
	}
}

/// Attempts to parse dependencies from top-level nodes in an OGDL graph.
private func dependenciesFromNodes<V: VersionType where V: NodeParseable>(nodes: [Node]) -> Result<[Dependency<V>]> {
	var dependencies: [Dependency<V>] = []

	for node in nodes {
		let result: Result<(Dependency<V>, Node?)> = dependencyFromNode(node)

		switch result {
		case let .Success(dependencyAndRemainder):
			let (dependency, remainder) = dependencyAndRemainder.unbox

			if let remainder = remainder {
				return failure(CarthageError.ParseError(description: "Unexpected node after parsing \(dependency): \(remainder)").error)
			} else {
				dependencies.append(dependency)
			}

		case let .Failure(error):
			return failure(error)
		}
	}

	return success(dependencies)
}

extension SemanticVersion: NodeParseable {
	private static func fromNode(node: Node?) -> Result<(SemanticVersion, Node?)> {
		if let node = node {
			return fromString(node.value).map { version in (version, node.children.first) }
		} else {
			return failure(CarthageError.ParseError(description: "expected semantic version").error)
		}
	}
}

extension PinnedVersion: NodeParseable {
	private static func fromNode(node: Node?) -> Result<(PinnedVersion, Node?)> {
		switch node?.value {
		case .Some(""):
			return failure(CarthageError.ParseError(description: "empty pinned version at \(node)").error)

		case let .Some(other):
			return success((self(other), node?.children.first))

		case .None:
			return failure(CarthageError.ParseError(description: "expected pinned version").error)
		}
	}
}

extension VersionSpecifier: NodeParseable {
	private static func fromNode(node: Node?) -> Result<(VersionSpecifier, Node?)> {
		let versionResult = SemanticVersion.fromNode(node?.children.first)

		switch node?.value {
		case .Some("=="):
			return versionResult.map { version, remainder in (Exactly(version), remainder) }

		case .Some(">="):
			return versionResult.map { version, remainder in (AtLeast(version), remainder) }

		case .Some("~>"):
			return versionResult.map { version, remainder in (CompatibleWith(version), remainder) }

		case let .Some(other):
			return success((GitReference(other), node?.children.first))

		case .None:
			return success((Any, nil))
		}
	}
}
