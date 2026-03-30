defmodule Awardflights.SasAwardApiTest do
  use ExUnit.Case, async: true

  alias Awardflights.SasAwardApi

  # Hard-coded session ID used in all requests
  @hardcoded_session_id "fbff2a07-057a-4d7b-ad56-5279c28137fe"

  setup do
    Application.put_env(:awardflights, :sas_award_api_plug, {Req.Test, Awardflights.SasAwardApi})
    on_exit(fn -> Application.delete_env(:awardflights, :sas_award_api_plug) end)
    :ok
  end

  describe "search_flights/4" do
    test "parses successful response with available flights" do
      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        response = %{
          "outboundFlights" => [
            %{
              "origin" => %{"code" => "GOT"},
              "destination" => %{"code" => "CDG"},
              "cabins" => [
                %{
                  "cabinName" => "Economy",
                  "fares" => [
                    %{
                      "bookingClass" => "X",
                      "avlSeats" => 9,
                      "points" => %{"base" => 24000}
                    },
                    %{
                      "bookingClass" => "V",
                      "avlSeats" => 5,
                      "points" => %{"base" => 18000}
                    }
                  ]
                },
                %{
                  "cabinName" => "Business",
                  "fares" => [
                    %{
                      "bookingClass" => "Z",
                      "avlSeats" => 2,
                      "points" => %{"base" => 75000}
                    }
                  ]
                }
              ]
            }
          ]
        }

        Req.Test.json(conn, response)
      end)

      assert {:ok, flights} = SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", "test_token")

      assert length(flights) == 3

      [economy_x, economy_v, business_z] = flights

      assert economy_x.departure == "GOT"
      assert economy_x.arrival == "CDG"
      assert economy_x.date == "2026-01-23"
      assert economy_x.booking_class == "X"
      assert economy_x.cabin == "Economy"
      assert economy_x.available_tickets == 9
      assert economy_x.points == 24000

      assert economy_v.booking_class == "V"
      assert economy_v.available_tickets == 5
      assert economy_v.points == 18000

      assert business_z.cabin == "Business"
      assert business_z.booking_class == "Z"
      assert business_z.available_tickets == 2
      assert business_z.points == 75000
    end

    test "filters out fares with zero available seats" do
      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        response = %{
          "outboundFlights" => [
            %{
              "origin" => %{"code" => "ARN"},
              "destination" => %{"code" => "LHR"},
              "cabins" => [
                %{
                  "cabinName" => "Economy",
                  "fares" => [
                    %{"bookingClass" => "X", "avlSeats" => 0, "points" => %{"base" => 24000}},
                    %{"bookingClass" => "V", "avlSeats" => 3, "points" => %{"base" => 18000}}
                  ]
                }
              ]
            }
          ]
        }

        Req.Test.json(conn, response)
      end)

      assert {:ok, flights} = SasAwardApi.search_flights("ARN", "LHR", "2026-02-01", "test_token")

      assert length(flights) == 1
      assert hd(flights).booking_class == "V"
    end

    test "returns empty list when no flights available" do
      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      assert {:ok, []} = SasAwardApi.search_flights("GOT", "NYC", "2026-03-01", "test_token")
    end

    test "handles missing outboundFlights key" do
      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        Req.Test.json(conn, %{})
      end)

      assert {:ok, []} = SasAwardApi.search_flights("GOT", "NYC", "2026-03-01", "test_token")
    end

    test "returns auth_expired error on 401 response" do
      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        conn
        |> Plug.Conn.put_status(401)
        |> Req.Test.json(%{"error" => "Unauthorized"})
      end)

      assert {:error, :auth_expired} =
               SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", "bad_token")
    end

    test "returns rate_limited error with remaining time on 429 response" do
      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{
          "bookingErrorType" => "TOO_MANY_REQUESTS",
          "statusCode" => 429,
          "payload" => %{"remainingTime" => 3541, "message" => "Too many requests"}
        })
      end)

      assert {:error, {:rate_limited, 3541}} =
               SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", "token")
    end

    test "returns default remaining time when payload missing on 429" do
      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        conn
        |> Plug.Conn.put_status(429)
        |> Req.Test.json(%{"error" => "Too Many Requests"})
      end)

      assert {:error, {:rate_limited, 60}} =
               SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", "token")
    end

    test "returns http_error for other error status codes" do
      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        conn
        |> Plug.Conn.put_status(500)
        |> Req.Test.json(%{"error" => "Internal Server Error"})
      end)

      assert {:error, {:http_error, 500, _body}} =
               SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", "token")
    end

    test "parses Format 2 response (session cookie auth) with points at cabin level" do
      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        response = %{
          "outboundFlights" => [
            %{
              "origin" => %{"code" => "GOT"},
              "destination" => %{"code" => "CDG"},
              "cabins" => [
                %{
                  "cabin" => "economy",
                  "productName" => "ECONOMY",
                  "price" => %{"points" => 24000},
                  "availableSeats" => 9,
                  "fares" => [
                    %{
                      "bookingClass" => "X",
                      "avlSeats" => 9
                    }
                  ]
                },
                %{
                  "cabin" => "business",
                  "productName" => "BUSINESS",
                  "price" => %{"points" => 75000},
                  "availableSeats" => 2,
                  "fares" => [
                    %{
                      "bookingClass" => "Z",
                      "avlSeats" => 2
                    }
                  ]
                }
              ]
            }
          ]
        }

        Req.Test.json(conn, response)
      end)

      # Use a session cookie (not a JWT)
      assert {:ok, flights} =
               SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", "session_cookie_value")

      assert length(flights) == 2

      [economy, business] = flights

      assert economy.departure == "GOT"
      assert economy.arrival == "CDG"
      assert economy.date == "2026-01-23"
      assert economy.booking_class == "X"
      assert economy.cabin == "Economy"
      assert economy.available_tickets == 9
      assert economy.points == 24000

      assert business.cabin == "Business"
      assert business.booking_class == "Z"
      assert business.available_tickets == 2
      assert business.points == 75000
    end

    test "filters out cabins with zero available seats in Format 2 response" do
      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        response = %{
          "outboundFlights" => [
            %{
              "origin" => %{"code" => "ARN"},
              "destination" => %{"code" => "LHR"},
              "cabins" => [
                %{
                  "cabin" => "economy",
                  "price" => %{"points" => 24000},
                  "availableSeats" => 0,
                  "fares" => [%{"bookingClass" => "X", "avlSeats" => 0}]
                },
                %{
                  "cabin" => "business",
                  "price" => %{"points" => 75000},
                  "availableSeats" => 3,
                  "fares" => [%{"bookingClass" => "Z", "avlSeats" => 3}]
                }
              ]
            }
          ]
        }

        Req.Test.json(conn, response)
      end)

      assert {:ok, flights} =
               SasAwardApi.search_flights("ARN", "LHR", "2026-02-01", "session_cookie")

      assert length(flights) == 1
      assert hd(flights).cabin == "Business"
    end
  end

  describe "JWT vs session cookie detection" do
    test "JWT with customerSessionId uses Bearer auth with hardcoded session ID" do
      # Real JWT structure with customerSessionId in payload
      # Header: {"alg":"RS256","typ":"JWT"}
      # Payload: {"customerSessionId":"test-session-123","sub":"user"}
      header = Base.url_encode64(~s({"alg":"RS256","typ":"JWT"}), padding: false)

      payload =
        Base.url_encode64(~s({"customerSessionId":"test-session-123","sub":"user"}),
          padding: false
        )

      signature = Base.url_encode64("fake-signature", padding: false)
      jwt_token = "#{header}.#{payload}.#{signature}"

      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        # Verify the hardcoded session ID header was sent (not extracted from JWT)
        session_id = Plug.Conn.get_req_header(conn, "sas-user-session-id")
        assert session_id == [@hardcoded_session_id]

        # Should use Bearer auth
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer #{jwt_token}"]

        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      assert {:ok, []} = SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", jwt_token)
    end

    test "invalid JWT falls back to session cookie auth with hardcoded session ID" do
      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        # Invalid JWT should be treated as session cookie with hardcoded session ID
        session_id = Plug.Conn.get_req_header(conn, "sas-user-session-id")
        assert session_id == [@hardcoded_session_id]

        # Should have cookie header instead
        cookie = Plug.Conn.get_req_header(conn, "cookie")
        assert cookie == ["__session=not-a-valid-jwt"]

        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      assert {:ok, []} = SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", "not-a-valid-jwt")
    end

    test "JWT without customerSessionId falls back to session cookie auth with hardcoded session ID" do
      header = Base.url_encode64(~s({"alg":"RS256","typ":"JWT"}), padding: false)
      payload = Base.url_encode64(~s({"sub":"user"}), padding: false)
      signature = Base.url_encode64("fake-signature", padding: false)
      jwt_token = "#{header}.#{payload}.#{signature}"

      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        # JWT without customerSessionId should be treated as session cookie with hardcoded session ID
        session_id = Plug.Conn.get_req_header(conn, "sas-user-session-id")
        assert session_id == [@hardcoded_session_id]

        # Should have cookie header instead
        cookie = Plug.Conn.get_req_header(conn, "cookie")
        assert cookie == ["__session=#{jwt_token}"]

        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      assert {:ok, []} = SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", jwt_token)
    end
  end

  describe "session cookie authentication" do
    test "sends cookie header when using single session cookie value" do
      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        # Verify cookie header was sent
        cookie = Plug.Conn.get_req_header(conn, "cookie")
        assert cookie == ["__session=my_session_cookie_123"]

        # Should have authorization: Bearer header (empty token for cookie auth)
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer"]

        # Should have hardcoded session ID header
        session_id = Plug.Conn.get_req_header(conn, "sas-user-session-id")
        assert session_id == [@hardcoded_session_id]

        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      assert {:ok, []} =
               SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", "my_session_cookie_123")
    end

    test "sends full cookie string with hardcoded session_id" do
      full_cookie =
        "__cf_bm=abc123; session_id=test-session-456; __session=encrypted_value; other=cookie"

      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        # Verify full cookie string was sent
        cookie = Plug.Conn.get_req_header(conn, "cookie")
        assert cookie == [full_cookie]

        # Should have hardcoded session ID header (ignores session_id in cookies)
        session_id = Plug.Conn.get_req_header(conn, "sas-user-session-id")
        assert session_id == [@hardcoded_session_id]

        # Should have authorization: Bearer header (empty token for cookie auth)
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer"]

        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      assert {:ok, []} = SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", full_cookie)
    end

    test "ignores explicit session_id parameter and uses hardcoded value" do
      full_cookie = "__cf_bm=abc123; session_id=wrong-id; __session=encrypted_value"
      explicit_session_id = "correct-user-id-from-header"

      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        # Verify full cookie string was sent
        cookie = Plug.Conn.get_req_header(conn, "cookie")
        assert cookie == [full_cookie]

        # Should use hardcoded session ID, ignoring the explicit parameter
        session_id = Plug.Conn.get_req_header(conn, "sas-user-session-id")
        assert session_id == [@hardcoded_session_id]

        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      assert {:ok, []} =
               SasAwardApi.search_flights(
                 "GOT",
                 "CDG",
                 "2026-01-23",
                 full_cookie,
                 explicit_session_id
               )
    end

    test "detects bearer token and uses authorization header with hardcoded session_id" do
      # Create a valid JWT with customerSessionId
      header = Base.url_encode64(~s({"alg":"RS256","typ":"JWT"}), padding: false)

      payload =
        Base.url_encode64(~s({"customerSessionId":"sess-123","sub":"user"}), padding: false)

      signature = Base.url_encode64("fake-signature", padding: false)
      jwt_token = "#{header}.#{payload}.#{signature}"

      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        # Verify authorization header was sent
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer #{jwt_token}"]

        # Should have hardcoded session ID header (ignores customerSessionId in JWT)
        session_id = Plug.Conn.get_req_header(conn, "sas-user-session-id")
        assert session_id == [@hardcoded_session_id]

        # Should NOT have cookie header
        cookie = Plug.Conn.get_req_header(conn, "cookie")
        assert cookie == []

        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      assert {:ok, []} = SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", jwt_token)
    end

    test "JWT with newlines from copy-paste is sanitized" do
      header = Base.url_encode64(~s({"alg":"RS256","typ":"JWT"}), padding: false)

      payload =
        Base.url_encode64(~s({"customerSessionId":"sess-123","sub":"user"}), padding: false)

      signature = Base.url_encode64("fake-signature", padding: false)
      jwt_token = "#{header}.#{payload}.#{signature}"

      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer #{jwt_token}"]

        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      assert {:ok, []} = SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", "#{jwt_token}\n")
    end

    test "JWT with 'Bearer ' prefix strips prefix before use" do
      header = Base.url_encode64(~s({"alg":"RS256","typ":"JWT"}), padding: false)

      payload =
        Base.url_encode64(~s({"customerSessionId":"sess-123","sub":"user"}), padding: false)

      signature = Base.url_encode64("fake-signature", padding: false)
      jwt_token = "#{header}.#{payload}.#{signature}"

      Req.Test.stub(Awardflights.SasAwardApi, fn conn ->
        auth = Plug.Conn.get_req_header(conn, "authorization")
        assert auth == ["Bearer #{jwt_token}"]

        Req.Test.json(conn, %{"outboundFlights" => []})
      end)

      assert {:ok, []} =
               SasAwardApi.search_flights("GOT", "CDG", "2026-01-23", "Bearer #{jwt_token}")
    end
  end
end
