--[[
    AtomicBinding (ModuleScript)
    Path: StarterPlayer → StarterPlayerScripts → RbxCharacterSounds
    Parent: RbxCharacterSounds
    ⚠️  NESTED SCRIPT: This script is inside another script
    Exported: 2026-09-23 00:26:24
]]
local ROOT_ALIAS = "root"

local function parsePath(pathStr)
	local pathArray = string.split(pathStr, "/")
	for idx = #pathArray, 1, -1 do
		if pathArray[idx] == "" then
			table.remove(pathArray, idx)
		end
	end
	return pathArray
end

local function isManifestResolved(resolvedManifest, manifestSizeTarget)
	local manifestSize = 0
	for _ in pairs(resolvedManifest) do
		manifestSize += 1
	end

	assert(manifestSize <= manifestSizeTarget, manifestSize)
	return manifestSize == manifestSizeTarget
end

local function unbindNodeDescend(node, resolvedManifest)
	if node.instance == nil then
		return
	end

	node.instance = nil

	local connections = node.connections
	if connections then
		for _, conn in ipairs(connections) do
			conn:Disconnect()
		end
		table.clear(connections)
	end

	if resolvedManifest and node.alias then
		resolvedManifest[node.alias] = nil
	end

	local children = node.children
	if children then
		for _, childNode in pairs(children) do
			unbindNodeDescend(childNode, resolvedManifest)
		end
	end
end

local AtomicBinding = {}
AtomicBinding.__index = AtomicBinding

function AtomicBinding.new(manifest, boundFn)
	local dtorMap = {}
	local connections = {}
	local rootInstToRootNode = {}
	local rootInstToManifest = {}

	local parsedManifest = {}
	local manifestSizeTarget = 1
	
	for alias, rawPath in pairs(manifest) do
		parsedManifest[alias] = parsePath(rawPath)
		manifestSizeTarget += 1
	end

	return setmetatable({
		_boundFn = boundFn,
		_parsedManifest = parsedManifest,
		_manifestSizeTarget = manifestSizeTarget,
		
		_dtorMap = dtorMap,
		_connections = connections,
		_rootInstToRootNode = rootInstToRootNode,
		_rootInstToManifest = rootInstToManifest,
	}, AtomicBinding)
end

function AtomicBinding:_startBoundFn(root, resolvedManifest)
	local boundFn = self._boundFn
	local dtorMap = self._dtorMap
	
	local oldDtor = dtorMap[root]
	if oldDtor then
		oldDtor()
		dtorMap[root] = nil
	end

	local dtor = boundFn(resolvedManifest)
	if dtor then
		dtorMap[root] = dtor
	end
end

function AtomicBinding:_stopBoundFn(root)
	local dtorMap = self._dtorMap
	
	local dtor = dtorMap[root]
	if dtor then
		dtor()
		dtorMap[root] = nil
	end
end

function AtomicBinding:bindRoot(root)
	debug.profilebegin("AtomicBinding:BindRoot")
	
	local parsedManifest = self._parsedManifest
	local rootInstToRootNode = self._rootInstToRootNode
	local rootInstToManifest = self._rootInstToManifest
	local manifestSizeTarget = self._manifestSizeTarget
	
	assert(rootInstToManifest[root] == nil)

	local resolvedManifest = {}
	rootInstToManifest[root] = resolvedManifest

	debug.profilebegin("BuildTree")

	local rootNode = {}
	rootNode.alias = ROOT_ALIAS
	rootNode.instance = root
	if next(parsedManifest) then
		rootNode.children = {}
		rootNode.connections = {}
	end

	rootInstToRootNode[root] = rootNode

	for alias, parsedPath in pairs(parsedManifest) do
		local parentNode = rootNode

		for idx, childName in ipairs(parsedPath) do
			local leaf = idx == #parsedPath
			local childNode = parentNode.children[childName] or {}

			if leaf then
				if childNode.alias ~= nil then
					error("Multiple aliases assigned to one instance")
				end

				childNode.alias = alias

			else
				childNode.children = childNode.children or {}
				childNode.connections = childNode.connections or {}
			end

			parentNode.children[childName] = childNode
			parentNode = childNode
		end
	end

	debug.profileend()

	local function processNode(node)
		local instance = assert(node.instance)

		local children = node.children
		local alias = node.alias
		local isLeaf = not children

		if alias then
			resolvedManifest[alias] = instance
		end

		if not isLeaf then
			local function processAddChild(childInstance)
				local childName = childInstance.Name
				local childNode = children[childName]
				if not childNode or childNode.instance ~= nil then
					return
				end

				childNode.instance = childInstance
				processNode(childNode)
			end

			local function processDeleteChild(childInstance)
				local childName = childInstance.Name
				local childNode = children[childName]

				if not childNode then
					return
				end

				if childNode.instance ~= childInstance then
					return
				end

				self:_stopBoundFn(root)
				unbindNodeDescend(childNode, resolvedManifest)

				assert(childNode.instance == nil)

				local replacementChild = instance:FindFirstChild(childName)
				if replacementChild then
					processAddChild(replacementChild)
				end
			end

			for _, child in ipairs(instance:GetChildren()) do
				processAddChild(child)
			end

			table.insert(node.connections, instance.ChildAdded:Connect(processAddChild))
			table.insert(node.connections, instance.ChildRemoved:Connect(processDeleteChild))
		end

		if isLeaf and isManifestResolved(resolvedManifest, manifestSizeTarget) then
			self:_startBoundFn(root, resolvedManifest)
		end
	end

	debug.profilebegin("ResolveTree")
	processNode(rootNode)
	debug.profileend()
	
	debug.profileend()
end

function AtomicBinding:unbindRoot(root)
	local rootInstToRootNode = self._rootInstToRootNode
	local rootInstToManifest = self._rootInstToManifest
	
	self:_stopBoundFn(root)

	local rootNode = rootInstToRootNode[root]
	if rootNode then
		local resolvedManifest = assert(rootInstToManifest[root])
		unbindNodeDescend(rootNode, resolvedManifest)
		rootInstToRootNode[root] = nil
	end

	rootInstToManifest[root] = nil
end

function AtomicBinding:destroy()
	debug.profilebegin("AtomicBinding:destroy")

	for _, dtor in pairs(self._dtorMap) do
		dtor:destroy()
	end
	table.clear(self._dtorMap)

	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	table.clear(self._connections)

	local rootInstToManifest = self._rootInstToManifest
	for rootInst, rootNode in pairs(self._rootInstToRootNode) do
		local resolvedManifest = assert(rootInstToManifest[rootInst])
		unbindNodeDescend(rootNode, resolvedManifest)
	end
	table.clear(self._rootInstToManifest)
	table.clear(self._rootInstToRootNode)

	debug.profileend()
end

return AtomicBinding
