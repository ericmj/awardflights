defmodule AwardflightsWeb.PageController do
  use AwardflightsWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
