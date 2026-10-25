-- Cycles through all 1000 rows of the items table: /db/item/<1..1000>
local n = 0
request = function()
  n = n + 1
  return wrk.format("GET", "/db/item/" .. (n % 1000 + 1))
end
