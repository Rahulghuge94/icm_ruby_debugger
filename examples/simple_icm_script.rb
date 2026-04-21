# Small script for checking VS Code breakpoints through IExchange.exe.

message = 'hello from ICM embedded Ruby'
count = 3

count.times do |index|
  value = index + 1
  puts "#{message}: #{value}"
end

puts 'done'
