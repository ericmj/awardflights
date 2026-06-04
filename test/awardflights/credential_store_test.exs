defmodule Awardflights.CredentialStoreTest do
  use ExUnit.Case, async: false

  alias Awardflights.CredentialStore

  setup do
    tmp =
      Path.join(System.tmp_dir!(), "credentials_test_#{System.unique_integer([:positive])}.csv")

    Application.put_env(:awardflights, :credentials_file, tmp)
    CredentialStore.clear_all()

    on_exit(fn ->
      File.rm(tmp)
      Application.delete_env(:awardflights, :credentials_file)
    end)

    {:ok, tmp: tmp}
  end

  test "put_all then list round-trips per source" do
    CredentialStore.put_all(:award, [%{name: "A1", value: "tok1"}, %{name: "A2", value: "tok2"}])
    CredentialStore.put_all(:offers, [%{name: "O1", value: "cookie1"}])

    assert CredentialStore.list(:award) ==
             [%{name: "A1", value: "tok1"}, %{name: "A2", value: "tok2"}]

    assert CredentialStore.list(:offers) == [%{name: "O1", value: "cookie1"}]
  end

  test "put_all replaces all rows for a source, leaving the other source intact" do
    CredentialStore.put_all(:award, [%{name: "A1", value: "tok1"}])
    CredentialStore.put_all(:offers, [%{name: "O1", value: "c1"}])
    CredentialStore.put_all(:award, [%{name: "A2", value: "tok2"}])

    assert CredentialStore.list(:award) == [%{name: "A2", value: "tok2"}]
    assert CredentialStore.list(:offers) == [%{name: "O1", value: "c1"}]
  end

  test "preserves commas inside the value (last column) across a disk reload" do
    CredentialStore.put_all(:offers, [%{name: "O1", value: "a=1; b=2,3; c=4"}])
    CredentialStore.reload()
    assert CredentialStore.list(:offers) == [%{name: "O1", value: "a=1; b=2,3; c=4"}]
  end

  test "survives reload from disk", %{tmp: tmp} do
    CredentialStore.put_all(:award, [%{name: "A1", value: "tok1"}])
    assert File.exists?(tmp)
    CredentialStore.reload()
    assert CredentialStore.list(:award) == [%{name: "A1", value: "tok1"}]
  end

  test "strips newlines and commas from name, newlines from value" do
    CredentialStore.put_all(:award, [%{name: "Acc,1\n", value: "tok\nen"}])
    assert CredentialStore.list(:award) == [%{name: "Acc1", value: "token"}]
  end

  test "writes file with 0600 permissions", %{tmp: tmp} do
    CredentialStore.put_all(:award, [%{name: "A1", value: "t"}])
    assert rem(File.stat!(tmp).mode, 0o1000) == 0o600
  end
end
