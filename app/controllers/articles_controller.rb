class ArticlesController < ApplicationController
  before_action :set_article
  before_action :check_article
  before_action :check_if_article_locked, only: [:edit, :update, :destroy, :undelete, :close, :reopen]

  def show
    if @article.deleted?
      check_your_privilege('flag_curate', @article) # || return
    end
  end

  def share
    redirect_to article_path(params[:id])
  end

  def edit; end

  def update
    can_post_in_category = @article.category.present? &&
                           (@article.category.min_trust_level || -1) <= current_user&.trust_level
    unless current_user&.has_post_privilege?('edit_posts', @article) && can_post_in_category
      return update_as_suggested_edit
    end

    tags_cache = params[:article][:tags_cache]&.reject { |e| e.to_s.empty? }
    after_tags = Tag.where(tag_set_id: @article.category.tag_set_id, name: tags_cache)

    if @article.tags == after_tags && @article.body_markdown == params[:article][:body_markdown] &&
       @article.title == params[:article][:title]
      flash[:danger] = "No changes were saved because you didn't edit the post."
      return redirect_to article_path(@article)
    end

    body_rendered = helpers.post_markdown(:article, :body_markdown)
    before = { body: @article.body_markdown, title: @article.title, tags: @article.tags }
    if @article.update(article_params.merge(tags_cache: tags_cache, body: body_rendered,
                                            last_activity: DateTime.now, last_activity_by: current_user,
                                            last_edited_at: DateTime.now, last_edited_by: current_user))
      PostHistory.post_edited(@article, current_user, before: before[:body],
                              after: params[:article][:body_markdown], comment: params[:edit_comment],
                              before_title: before[:title], after_title: params[:article][:title],
                              before_tags: before[:tags], after_tags: after_tags)
      redirect_to share_article_path(@article)
    else
      render :edit
    end
  end

  def update_as_suggested_edit
    return if check_edits_limit! @article

    body_rendered = helpers.post_markdown(:article, :body_markdown)
    new_tags_cache = params[:article][:tags_cache]&.reject(&:empty?)

    body_markdown = if params[:article][:body_markdown] != @article.body_markdown
                      params[:article][:body_markdown]
                    end

    if @article.tags_cache == new_tags_cache && @article.body_markdown == params[:article][:body_markdown] &&
       @article.title == params[:article][:title]
      flash[:danger] = "No changes were saved because you didn't edit the post."
      return redirect_to article_path(@article)
    end

    updates = {
      post: @article,
      user: current_user,
      community: @article.community,
      body: body_rendered,
      title: params[:article][:title] == @article.title ? nil : params[:article][:title],
      tags_cache: new_tags_cache == @article.tags_cache ? @article.tags_cache : new_tags_cache,
      body_markdown: body_markdown,
      comment: params[:edit_comment],
      active: true, accepted: false,
      decided_at: nil, decided_by: nil,
      rejected_comment: nil
    }

    @edit = SuggestedEdit.new(updates)
    if @edit.save
      @article.user.create_notification("Edit suggested on your post #{@article.title.truncate(50)}",
                                        article_url(@article))
      redirect_to share_article_path(@article)
    else
      @article.errors = @edit.errors
      render :edit
    end
  end

  def destroy
    unless check_your_privilege('flag_curate', @article, false)
      flash[:danger] = helpers.ability_err_msg(:flag_curate, 'delete this article')
      redirect_to article_path(@article) && return
    end

    if @article.deleted
      flash[:danger] = "Can't delete a deleted post."
      redirect_to article_path(@article) && return
    end

    if @article.update(deleted: true, deleted_at: DateTime.now, deleted_by: current_user,
                       last_activity: DateTime.now, last_activity_by: current_user)
      PostHistory.post_deleted(@article, current_user)
    else
      flash[:danger] = "Can't delete this post right now. Try again later."
    end
    redirect_to article_path(@article)
  end

  def undelete
    unless check_your_privilege('flag_curate', @article, false)
      flash[:danger] = helpers.ability_err_msg(:flag_curate, 'undelete this article')
      redirect_to article_path(@article) && return
    end

    unless @article.deleted
      flash[:danger] = "Can't undelete an undeleted post."
      redirect_to article_path(@article) && return
    end

    if @article.deleted_by.is_moderator && !current_user.is_moderator
      flash[:danger] = 'You cannot undelete this post deleted by a moderator.'
      redirect_to(article_path(@article)) && return
    end

    if @article.update(deleted: false, deleted_at: nil, deleted_by: nil,
                       last_activity: DateTime.now, last_activity_by: current_user)
      PostHistory.post_undeleted(@article, current_user)
    else
      flash[:danger] = "Can't undelete this article right now. Try again later."
    end
    redirect_to article_path(@article)
  end

  private

  def set_article
    @article = Article.find params[:id]
    if @article.deleted && !current_user&.has_post_privilege?('flag_curate', @article)
      not_found
    end
  end

  def check_article
    unless @article.post_type_id == Article.post_type_id
      not_found
    end
  end

  def article_params
    params.require(:article).permit(:body_markdown, :title, :tags_cache)
  end

  def check_if_article_locked
    check_if_locked(@article)
  end
end
