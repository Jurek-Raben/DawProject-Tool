class "Cache"

Cache.storage = {}

function Cache:__init()
  self.storage = {}
end

function Cache:set(key, data)
  self.storage[key] = data
end

function Cache:get(key)
  return self.storage[key]
end
