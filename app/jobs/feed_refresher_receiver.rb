class FeedRefresherReceiver
  include Sidekiq::Worker
  sidekiq_options queue: :feed_refresher_receiver

  def perform(data)
    feed = Feed.find(data["feed"]["id"])
    if data["entries"].present?
      receive_entries(data["entries"], feed)
    end
    feed.update(data["feed"])
  end

  def receive_entries(items, feed)
    public_ids = items.map { |entry| entry["public_id"] }
    entries = Entry.where(public_id: public_ids).index_by(&:public_id)
    items.each do |item|
      entry = entries[item["public_id"]]
      update = item.delete("update")
      if entry && update == true
        update_entry(item, entry)
      elsif entry
        cache_public_id(item)
      else
        create_entry(item, feed)
      end
    rescue ActiveRecord::RecordNotUnique
      cache_public_id(item)
    rescue => exception
      unless exception.message =~ /Validation failed/i
        message = update ? "update" : "create"
        Honeybadger.notify(
          error_class: "FeedRefresherReceiver#" + message,
          error_message: "Entry #{message} failed",
          parameters: {feed_id: feed.id, item: item, exception: exception, backtrace: exception.backtrace}
        )
      end
    end
  end

  def create_entry(item, feed)
    if alternate_exists?(item)
      Librato.increment("entry.alternate_exists")
    else
      threader = Threader.new(item, feed)
      if !threader.thread
        feed.entries.create!(item)
        Librato.increment("entry.create")
      else
        Librato.increment("entry.thread")
      end
    end
  end

  def update_entry(item, entry)
    cache_public_id(item)

    return unless entry.published_recently?

    update = item.slice("author", "content", "title", "url", "entry_id", "data")
    update["summary"] = ContentFormatter.summary(update["content"], 256)

    current_content = entry.content.to_s.clone
    new_content = update["content"].to_s.clone

    if current_content.present? && entry.original.nil?
      update["original"] = build_original(entry)
    end

    entry.update(update)

    if significant_change?(current_content, new_content)
      create_update_notifications(entry)
    end

    if new_content.length == current_content.length
      Librato.increment("entry.no_change")
    end

    Librato.increment("entry.update")
  end

  def build_original(entry)
    {
      "author"    => entry.author,
      "content"   => entry.content,
      "title"     => entry.title,
      "url"       => entry.url,
      "entry_id"  => entry.entry_id,
      "published" => entry.published,
      "data"      => entry.data
    }
  end

  def significant_change?(current_content, new_content)
    return false if current_content.empty?

    original_length = Sanitize.fragment(current_content).length
    new_length = Sanitize.fragment(new_content).length
    new_length - original_length > 50
  rescue Exception => e
    Honeybadger.notify(
      error_class: "FeedRefresherReceiver#detect_significant_change",
      error_message: "detect_significant_change failed",
      parameters: {exception: e, backtrace: e.backtrace}
    )
    false
  end

  def create_update_notifications(entry)
    updated_entries = []

    subscription_user_ids = Subscription.where(feed_id: entry.feed_id, active: true, muted: false, show_updates: true).pluck(:user_id)
    unread_entries_user_ids = UnreadEntry.where(entry_id: entry.id, user_id: subscription_user_ids).pluck(:user_id)
    updated_entries_user_ids = UpdatedEntry.where(entry_id: entry.id, user_id: subscription_user_ids).pluck(:user_id)

    subscription_user_ids.each do |user_id|
      if !unread_entries_user_ids.include?(user_id) && !updated_entries_user_ids.include?(user_id)
        updated_entries << UpdatedEntry.new_from_owners(user_id, entry)
      end
    end
    UpdatedEntry.import(updated_entries, validate: false, on_duplicate_key_ignore: true)

    Librato.increment("entry.update_big")
  rescue Exception => e
    Honeybadger.notify(
      error_class: "FeedRefresherReceiver#create_update_notifications",
      error_message: "create_update_notifications failed",
      parameters: {exception: e, backtrace: e.backtrace}
    )
  end

  def cache_public_id(item)
    FeedbinUtils.update_public_id_cache(item["public_id"], item["content"], item.dig("data", "public_id_alt"))
  end

  def alternate_exists?(item)
    if item["data"] && item["data"]["public_id_alt"]
      FeedbinUtils.public_id_exists?(item["data"]["public_id_alt"])
    end
  end
end
