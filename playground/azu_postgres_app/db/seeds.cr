Azu::Database.seed do
  next if User.count > 0

  admin = User.create!(email: "admin@example.com", name: "Admin", role: "admin")
  authors = Array.new(4) { |i| User.create!(email: "author#{i + 1}@example.com", name: "Author #{i + 1}") }

  authors.each do |author|
    3.times do |n|
      post = Post.create!(user_id: author.id.not_nil!, title: "#{author.name}'s post ##{n + 1}", body: "Hello from #{author.name}.",
        status: n.zero? ? "draft" : "published")
      2.times { |c| Comment.create!(post_id: post.id.not_nil!, user_id: admin.id.not_nil!, body: "Comment #{c + 1}") }
    end
  end
end
